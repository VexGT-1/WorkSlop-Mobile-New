import Foundation

/// Real iOS 27 pairable-host implementation using the jkcoxson/idevice
/// Rust FFI (libidevice_ffi.a, built for aarch64-apple-ios).
///
/// Flow:
/// 1. `pairable_host_prepare("WorkSlop", ...)` → handle + Bonjour service
///    name + TXT records (XML plist) + altIRK.
/// 2. Open a POSIX TCP listener on an ephemeral port; publish
///    `_remotepairing-pairable-host._tcp` via NetService.
/// 3. User taps "WorkSlop" in Settings > Privacy & Security > Developer Mode.
/// 4. Device connects → `accept()` gives fd → `pairable_host_accept_fd`
///    (blocks) with PIN callback.
/// 5. PIN callback fires → show 6-digit code in UI.
/// 6. User types PIN on iPhone → handshake completes → pairing file handle.
/// 7. `rp_pairing_file_to_bytes` → save XML plist to PairingStore.fileURL
///    (+ persist altIRK alongside).
final class Pairing27Controller: ObservableObject {
    enum State: Equatable {
        case idle
        case advertising
        case pin(String)
        case done
        case failed(String)

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    @Published var state: State = .idle

    private var handle: UnsafeMutablePointer<PairableHostHandle>?
    private var netService: NetService?
    private var listenFD: Int32 = -1
    private var altIRK: [UInt8] = Array(repeating: 0, count: 16)
    private var acceptThread: Thread?
    private var stopped = false
    private let workQueue = DispatchQueue(label: "workslop.pairing27")

    func start() {
        stopped = false
        workQueue.async { [weak self] in
            self?.runPrepare()
        }
    }

    func stop() {
        stopped = true
        workQueue.async { [weak self] in
            self?.teardown()
            DispatchQueue.main.async { [weak self] in
                self?.state = .idle
            }
        }
    }

    // MARK: - Prepare (FFI)

    private func runPrepare() {
        var handle: UnsafeMutablePointer<PairableHostHandle>?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txtData: UnsafeMutablePointer<UInt8>?
        var txtLen: Int = 0
        var irk = [UInt8](repeating: 0, count: 16)

        let err = "WorkSlop".withCString { namePtr in
            irk.withUnsafeMutableBufferPointer { irkPtr in
                pairable_host_prepare(
                    namePtr, nil, false,
                    &handle, &serviceID, &txtData, &txtLen,
                    irkPtr.baseAddress
                )
            }
        }
        if let err {
            let msg = String(cString: err.pointee.message)
            idevice_error_free(err)
            setState(.failed("Prepare failed: \(msg)"))
            return
        }
        guard let handle, let serviceID, let txtData else {
            setState(.failed("Prepare returned null pointers"))
            return
        }
        self.handle = handle
        self.altIRK = irk

        let serviceName = String(cString: serviceID)
        idevice_string_free(serviceID)

        let txtBytes = Data(bytes: txtData, count: txtLen)
        idevice_data_free(txtData, txtLen)
        guard let txtDict = try? PropertyListSerialization.propertyList(
            from: txtBytes, format: nil) as? [String: String] else {
            setState(.failed("Could not parse TXT records"))
            teardown()
            return
        }

        do {
            let port = try openListener()
            publishBonjour(serviceName: serviceName, port: port, txtDict: txtDict)
            startAcceptLoop()
        } catch {
            setState(.failed("Listener failed: \(error.localizedDescription)"))
            teardown()
            return
        }
        setState(.advertising)
    }

    // MARK: - POSIX listener

    private func openListener() throws -> UInt16 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var no: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &no, socklen_t(MemoryLayout<Int32>.size))

        // Bind to :: port 0 (ephemeral), dual-stack.
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = 0
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        guard listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EIO) }

        // Read back the assigned port.
        var outAddr = sockaddr_in6()
        var outLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &outAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &outLen)
            }
        }
        let port = UInt16(bigEndian: outAddr.sin6_port)
        self.listenFD = fd
        return port
    }

    private func publishBonjour(serviceName: String, port: UInt16, txtDict: [String: String]) {
        let service = NetService(
            domain: "local.",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceName,
            port: Int32(port)
        )
        let txtData = NetService.data(fromTXTRecord: txtDict.reduce(into: [String: Data]()) {
            $0[$1.key] = $1.value.data(using: .utf8) ?? Data()
        })
        service.setTXTRecord(txtData)
        service.publish()
        self.netService = service
    }

    private func startAcceptLoop() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            while !self.stopped {
                var addr = sockaddr_storage()
                var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let fd = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.listenFD, $0, &len)
                    }
                }
                if fd < 0 {
                    if self.stopped { break }
                    continue
                }
                self.runHandshake(fd: fd)
                close(fd)
                break // one pairing per session
            }
        }
        thread.name = "workslop.pairing27.accept"
        thread.start()
        self.acceptThread = thread
    }

    // MARK: - Handshake (FFI, blocks)

    private func runHandshake(fd: Int32) {
        guard let handle else {
            setState(.failed("No handle"))
            return
        }

        // PIN callback: capture self weakly via context.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let pinCb: PairableHostPinCb = { pinPtr, ctxPtr in
            guard let pinPtr, let ctxPtr else { return }
            let pin = String(cString: pinPtr)
            let me = Unmanaged<Pairing27Controller>.fromOpaque(ctxPtr).takeUnretainedValue()
            DispatchQueue.main.async {
                me.state = .pin(pin)
            }
        }

        var pairingFile: UnsafeMutablePointer<RpPairingFileHandle>?
        let err = pairable_host_accept_fd(
            handle, fd, pinCb, ctx, nil, &pairingFile
        )
        if let err {
            let msg = String(cString: err.pointee.message)
            idevice_error_free(err)
            setState(.failed("Pairing failed: \(msg)"))
            return
        }
        guard let pairingFile else {
            setState(.failed("Pairing returned no file"))
            return
        }
        defer { rp_pairing_file_free(pairingFile) }

        // Serialize to XML plist bytes and save.
        var dataPtr: UnsafeMutablePointer<UInt8>?
        var dataLen: Int = 0
        if let e2 = rp_pairing_file_to_bytes(pairingFile, &dataPtr, &dataLen) {
            let msg = String(cString: e2.pointee.message)
            idevice_error_free(e2)
            setState(.failed("Serialize failed: \(msg)"))
            return
        }
        guard let dataPtr else {
            setState(.failed("Serialize returned null"))
            return
        }
        let plistData = Data(bytes: dataPtr, count: dataLen)
        idevice_data_free(dataPtr, dataLen)

        do {
            try plistData.write(to: PairingStore.fileURL, options: .atomic)
            // Persist altIRK alongside (StikPair lesson: device won't
            // recognize the host again without a stable altIRK).
            let irkURL = PairingStore.fileURL.deletingLastPathComponent()
                .appendingPathComponent("altIRK.bin")
            try Data(altIRK).write(to: irkURL, options: .atomic)
            setState(.done)
        } catch {
            setState(.failed("Save failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    private func setState(_ s: State) {
        DispatchQueue.main.async { [weak self] in
            self?.state = s
        }
    }

    private func teardown() {
        stopped = true
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        if let h = handle { pairable_host_free(h); handle = nil }
        netService?.stop()
        netService = nil
    }

    deinit {
        if listenFD >= 0 { close(listenFD) }
        if let h = handle { pairable_host_free(h) }
    }
}
