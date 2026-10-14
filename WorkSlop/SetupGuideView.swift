import SwiftUI

/// Setup guide: 4 langkah jelas biar Apply bisa jalan.
///
/// Langkahnya:
/// 1. Install LocalDevVPN (tunnel app terpisah)
/// 2. Export pairing file dari device
/// 3. Import pairing file ke app ini
/// 4. Apply tweaks
///
/// Setiap langkah punya error message spesifik, bukan "backend mati".
/// LocalDevVPN adalah app TERPISAH yang harus diinstall manual - bukan
/// bagian dari repo ini, jadi diinstruksikan ke user untuk mencari
/// package yang sesuai (mirip SideStore/Nugget class apps).

struct SetupGuideView: View {
    var body: some View {
        NavigationStack {
            List {
                // MARK: - Langkah 1: Tunnel app
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Langkah 1 — Install tunnel app (LocalDevVPN)")
                            .font(.headline)
                        Text(
                            "WorkSlop berbicara ke lockdownd lewat loopback tunnel " +
                            "(127.0.0.1:62078) ke HP kamu sendiri. Tunnel-nya harus " +
                            "diinstall sebagai app TERPISAH."
                        )
                        .font(.subheadline)
                        Text(
                            "Cari & install app tunnel loopback untuk lockdownd " +
                            "(LocalDevVPN atau sejenisnya — package pihak ketiga, " +
                            "bukan bagian dari repo WorkSlop ini). Install lewat " +
                            "TrollStore, AltStore, Sideloadly, atau cara sideload " +
                            "lain yang kamu pakai. Pasang, lalu nyalakan tunnelnya."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } header {
                    Text("Install tunnel app")
                } footer {
                    Text(
                        "Tanpa tunnel app yang aktif, bar VPN di layar Home akan " +
                        "bilang \"Tidak terdeteksi\" dan Apply tidak akan bisa " +
                        "jalan. Tunnel harus jalan BERDampingan dengan app ini."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                // MARK: - Langkah 2: Export pairing
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Langkah 2 — Export pairing file (.plist)")
                            .font(.headline)
                        Text(
                            "Kamu butuh file pairing dari iPhone ini. Export pake " +
                            "idevicepair di komputer:"
                        )
                        .font(.subheadline)
                        CodeBlock(
                            text: "idevicepair pair -d <UDID_DEVICE> -o <NAMA_FILE.plist>",
                            note: "Ganti <UDID_DEVICE> sama UDID iPhone kamu. " +
                                   "Kamu bisa lihat UDID via Finder/iTunes atau " +
                                   "\"idevice_id --list\""
                        )
                        Text(
                            "Untuk iOS 17+: pairing file baru (RemotePairing: " +
                            "identifier + private_key + public_key). Untuk iOS " +
                            "lama: pairing legacy (HostID + certificates)."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } header {
                    Text("Export pairing file")
                } footer {
                    Text(
                        "Jangan share pairing file ini ke orang lain - dia " +
                        "memberi akses penuh ke lockdownd device kamu. Simpan di " +
                        "tempat aman, cuma buat device ini."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                // MARK: - Langkah 3: Import pairing
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Langkah 3 — Import pairing file ke WorkSlop")
                            .font(.headline)
                        Text(
                            "Buka app WorkSlop → Home → pilih tombol import " +
                            "pairing file → pilih file pairing (.plist) yang " +
                            "kamu export tadi."
                        )
                        .font(.subheadline)
                        Text(
                            "App akan memvalidasi: pairing iOS 17+ (RemotePairing) " +
                            "atau pairing legacy. Kalau salah format, error " +
                            "menjelaskan persis kesalahannya - export ulang."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } header {
                    Text("Import pairing file")
                } footer {
                    Text(
                        "Import cuma sekali. App simpan pairing file di dalam " +
                        "container-nya dan otomatis dipakai pas Apply."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                // MARK: - Langkah 4: Apply
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Langkah 4 — Apply tweaks")
                            .font(.headline)
                        Text(
                            "1. Pastikan bar VPN di Home bilang \"DETECTED\" " +
                            "(tunnel app aktif & pairing file terimpor).\n" +
                            "2. Pilih tweak yang mau di-apply di menu Tweaks.\n" +
                            "3. Matikan Find My (wajib untuk iOS 27+).\n" +
                            "4. Tekan \"Apply now\"."
                        )
                        .font(.subheadline)
                        Text(
                            "App bakal ngelakuin: backup full → payload → modify " +
                            "→ restore full → restart. Progress & error " +
                            "ditampilkan per fase (backup/restore/handshake/tunnel)"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } header {
                    Text("Apply tweaks")
                } footer {
                    Text(
                        "App ini GAK bisa reboot iPhone kamu. Setelah Apply, " +
                        "shut down manual via Settings → General → Shut Down, " +
                        "lalu nyalain lagi & cek tweak-nya."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                // MARK: - Troubleshooting
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("🔧 Troubleshooting cepat")
                            .font(.headline)
                        TroubleshootItem(
                            question: "Bar VPN bilang \"Tidak terdeteksi\"",
                            answer: "Install & jalankan LocalDevVPN dulu. Buka tunnel " +
                                     "app → nyalakan loopback tunnel → cek lagi."
                        )
                        TroubleshootItem(
                            question: "\"Pairing file tidak diimpor\"",
                            answer: "Export pairing file lagi pake idevicepair. Pastikan " +
                                     "file .plist yang kamu pilih itu pairing asli, " +
                                     "bukan file sampah."
                        )
                        TroubleshootItem(
                            question: "Apply gagal, muncul error spesifik",
                            answer: "Copy teks error lengkap dari section Result di Apply. " +
                                     "Error menyebut fase mana yang gagal (backup / " +
                                     "restore / handshake / tunnel) - itu petunjuk " +
                                     "fix-nya."
                        )
                        TroubleshootItem(
                            question: "Aplikasi crash pas klik \"Setup guide\"",
                            answer: "Ini bug - setup guide belum tersedia. Hubungin " +
                                     "developer. Coba Settings → Info → baca " +
                                     "keterangan Help di sana."
                        )
                    }
                } header {
                    Text("Troubleshooting")
                } footer {
                    Text(
                        "Catatan jujur: fitur backup/restore on-device belum " +
                        "terverifikasi 100% di semua device. App ngakuin " +
                        "\"belum punya mesin restore on-device yang " +
                        "terverifikasi\". Kalau gagal, tidak ada yang merusak " +
                        "device kecuali kamu lanjutkan setelah risk warning."
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Block kode untuk command idevicepair
struct CodeBlock: View {
    let text: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .cornerRadius(6)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Item troubleshooting question/answer
struct TroubleshootItem: View {
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("• \(question)")
                .font(.subheadline)
                .foregroundStyle(.primary)
            Text(answer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SetupGuideView()
}
