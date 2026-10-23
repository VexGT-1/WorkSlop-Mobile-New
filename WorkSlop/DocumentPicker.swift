import UIKit
import UniformTypeIdentifiers

/// Presents UIDocumentPickerViewController straight from UIKit.
///
/// SwiftUI's `.fileImporter` on the home screen shared its view with two
/// `.sheet` modifiers (and the intro sheet above it). In that setup the
/// picker opens, but tapping a file does nothing: SwiftUI loses the
/// presentation's callback, so the pick is never delivered. Presenting
/// the UIKit picker ourselves from the top-most view controller avoids the
/// whole SwiftUI presentation chain. `asCopy` hands back a file already
/// copied into our sandbox, so no security scope or iCloud download dance.
@MainActor
enum DocumentPicker {
    private static var delegate: Delegate?

    static func present(types: [UTType], onPick: @escaping (URL?) -> Void) {
        guard let top = topViewController() else { onPick(nil); return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        let d = Delegate { url in
            onPick(url)
            delegate = nil
        }
        delegate = d                   // the picker only holds its delegate weakly
        picker.delegate = d
        top.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            done(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            done(nil)
        }
    }
}
