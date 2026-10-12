import SwiftUI

/// First-launch introduction, shown once. Plain text pages — what
/// WorkSlop Mobile supports, and what it needs before anything is
/// applied. No animation, no cards.
struct IntroView: View {
    @AppStorage("seenIntro") private var seenIntro = false
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage(
                    title: "WorkSlop",
                    lines: [
                        "On-device tweaks for this iPhone: Liquid Glass, Status Bar, Daemons, Apple Internal, SpringBoard, Custom Icons and PosterBoard.",
                        "This device: \(DeviceStatus.modelOrDash) \u{2022} iOS \(DeviceInfoEx.fullVersion)",
                    ])
                .tag(0)

                introPage(
                    title: "Supported iOS",
                    lines: [
                        "Liquid Glass (regular set): iOS 26.0 and later.",
                        "Liquid Glass iOS 26.6.1 RC S8: iOS 26.6.x builds 23G82/23G83 only.",
                        "Status Bar classic options: iOS 26.x (iOS 27 keeps carrier text only).",
                        "Most tweaks ride Partial restore (max iOS 26); the S8 set uses full backup (all data) on iOS 26.6.1. On iOS 27, features whose support reaches 27 ride Full backup \u{2192} modify \u{2192} restore.",
                        "Devices below iOS 16.0 or above iOS 27 get an \"iOS version not supported\" notice instead of this app.",
                    ])
                .tag(1)

                introPage(
                    title: "Before you apply",
                    lines: [
                        "Import the pairing file (.plist) in the Status section.",
                        "Applies are designed to run over a loopback VPN tunnel to this same phone.",
                        "The app cannot reboot your iPhone \u{2014} after an apply you restart manually.",
                        "Cancel only unstages: nothing is in flight yet.",
                        "Apply builds the real payload on this phone. Sending it to the system waits on the on-device restore engine, which is not built yet.",
                    ])
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button(page == 2 ? "Start" : "Continue") {
                if page == 2 {
                    seenIntro = true
                    dismiss()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .accessibilityIdentifier("intro-continue")
        }
    }

    private func introPage(title: String, lines: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title.weight(.bold))
                    .padding(.top, 32)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
        }
    }
}
