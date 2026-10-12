import Foundation
import UserNotifications

// MARK: - Phase 5: RESTART (with restart notification)
//
// Tries the lockdown reboot first. Without a transport that throws
// `.unimplemented`, and the phase degrades HONESTLY: it schedules a real
// local notification telling the user to restart manually, and reports
// `.manualRestartNotified` — never `.deviceRebooted`.

enum RestartPhase {
    enum Result: Sendable {
        /// The device rebooted over lockdown. bootVerified=false does NOT
        /// mean bricked — only that it hasn't come back on the wire yet
        /// (still booting, or stuck on the Apple logo). Reported honestly.
        case deviceRebooted(bootVerified: Bool)
        /// No transport: a real local notification was scheduled asking
        /// the user to restart manually. `notificationScheduled` is false
        /// when notifications are denied — also reported honestly.
        case manualRestartNotified(notificationScheduled: Bool)
    }

    static func run(
        transport: DeviceTransport,
        progress: @Sendable (RestoreProgress) -> Void
    ) async throws -> Result {
        progress(RestoreProgress(phase: .restart, fraction: 0.10, message: "Restarting device…"))
        do {
            try await transport.rebootDevice()
        } catch let error as RestoreError {
            // Only the missing-transport case degrades to manual.
            // Anything else is a real failure and propagates.
            guard case .unimplemented = error else { throw error }
            progress(RestoreProgress(phase: .restart, fraction: 0.50, message: "Scheduling restart reminder…"))
            let scheduled = await scheduleRestartNotification()
            progress(RestoreProgress(
                phase: .restart,
                fraction: 1.0,
                message: scheduled ? "Restart reminder scheduled — please restart your iPhone."
                                   : "Could not schedule the reminder (notifications denied) — please restart your iPhone manually."
            ))
            return .manualRestartNotified(notificationScheduled: scheduled)
        }

        // The pre-reboot session is dead by definition: verify the device
        // came back with FRESH lockdown sessions (desktop:
        // wait_for_ios27_device_online). A timeout is reported honestly —
        // never as success, never as bricked.
        progress(RestoreProgress(phase: .restart, fraction: 0.60,
                                 message: "Waiting for the device to come back online…"))
        let online = await transport.waitForDeviceOnline(timeoutSeconds: 300)
        progress(RestoreProgress(
            phase: .restart,
            fraction: 1.0,
            message: online
                ? "Device is back online."
                : "Device has not come back online within 5 minutes — it may still be booting " +
                  "or stuck on the Apple logo. The full backup is kept on this computer."
        ))
        return .deviceRebooted(bootVerified: online)
    }

    private static func scheduleRestartNotification() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return false }
        case .denied:
            return false
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = "Restart your iPhone"
        content.body = "WorkSlop finished applying tweaks. Restart now so the changes take effect."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "workslop-restart-reminder",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
