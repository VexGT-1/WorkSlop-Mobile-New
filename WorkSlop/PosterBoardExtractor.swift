import Foundation
import ZIPFoundation

/// Extracts imported .tendies zips into PosterBoard restore files,
/// following the desktop's posterboard_tweak.py routing.
///
/// Desktop rules mirrored here:
/// - Structure version 59 on iOS 16, 61 on iOS 17+ (PayloadSpecCatalog.pbStructure).
/// - Descriptor folders (name contains "descriptor", case-insensitive) are
///   routed to /Library/Application Support/PRBPosterExtensionDataStore/
///   {version}/Extensions/{ext}/descriptors, where ext is derived from the
///   descriptor's parent folder or name keywords (video/photos ->
///   PhotosPosterProvider, mercury -> MercuryPoster, else
///   WallpaperKit.CollectionsPoster).
/// - Domain is always AppDomain-com.apple.PosterBoard.
/// - Zip-slip protection: entries with ".." or absolute paths are skipped.
///
/// Honest simplifications vs desktop:
/// - No UUID randomization of descriptor folders (desktop randomizes to
///   avoid collisions); the imported layout is delivered as-is.
/// - No plist identifier rewriting; no configurations/database mode.
/// - Video tendies (.batter templates, freeze-frame/loop builders) are
///   out of scope — only plain .tendies descriptor zips.
enum PosterBoardExtractor {
    static let maxTendiesPerRestore = 5
    static let domain = "AppDomain-com.apple.PosterBoard"

    /// One extracted file ready for the restore payload.
    struct ExtractedFile {
        let restorePath: String
        let localURL: URL
    }

    /// Extracts a .tendies zip and maps its descriptor files to restore
    /// paths. Returns the files plus any warnings (skipped entries, etc.).
    static func extract(
        tendiesURL: URL,
        structureVersion: Int,
        stagingDir: URL
    ) -> (files: [ExtractedFile], warnings: [String]) {
        var files: [ExtractedFile] = []
        var warnings: [String] = []

        guard let archive = Archive(url: tendiesURL, accessMode: .read) else {
            return ([], ["\(tendiesURL.lastPathComponent): not a readable zip - skipped."])
        }

        // Extract to a unique temp dir with zip-slip protection.
        let extractDir = stagingDir
            .appendingPathComponent("tendies-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        for entry in archive {
            let name = entry.path
            // Zip-slip guard: skip absolute paths and parent traversals.
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                warnings.append("\(tendiesURL.lastPathComponent): skipped unsafe entry '\(name)'.")
                continue
            }
            if name.hasPrefix("__MACOSX/") || name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            let dest = extractDir.appendingPathComponent(name)
            do {
                if entry.type == .directory {
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try archive.extract(entry, to: dest)
                }
            } catch {
                warnings.append("\(tendiesURL.lastPathComponent): failed to extract '\(name)' (\(error.localizedDescription)).")
            }
        }

        // Walk for descriptor folders and route their contents.
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ([], ["\(tendiesURL.lastPathComponent): could not walk extracted contents."])
        }
        for case let dirURL as URL in enumerator {
            guard (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let folderName = dirURL.lastPathComponent
            guard folderName.lowercased().contains("descriptor") else { continue }
            enumerator.skipDescendants()

            let ext = extensionFor(descriptorURL: dirURL)
            let base = "/Library/Application Support/PRBPosterExtensionDataStore/\(structureVersion)/Extensions/\(ext)/descriptors/\(folderName)"

            guard let inner = fm.enumerator(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let fileURL as URL in inner {
                guard (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else { continue }
                let rel = fileURL.path.replacingOccurrences(of: dirURL.path + "/", with: "")
                // Copy into staging so BuiltFile.url points at a stable location.
                let staged = stagingDir
                    .appendingPathComponent("pb-\(UUID().uuidString)-\(fileURL.lastPathComponent)")
                do {
                    if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                    try fm.copyItem(at: fileURL, to: staged)
                    files.append(ExtractedFile(restorePath: "\(base)/\(rel)", localURL: staged))
                } catch {
                    warnings.append("\(tendiesURL.lastPathComponent): could not stage '\(rel)' (\(error.localizedDescription)).")
                }
            }
        }

        if files.isEmpty {
            warnings.append("\(tendiesURL.lastPathComponent): no descriptor folders found - nothing to deliver.")
        }
        return (files, warnings)
    }

    /// Desktop extension heuristic (posterboard_tweak.py): the provider
    /// extension is the descriptor's parent folder when it looks like a
    /// bundle ID; otherwise keyword-matched.
    private static func extensionFor(descriptorURL: URL) -> String {
        let parent = descriptorURL.deletingLastPathComponent().lastPathComponent
        if parent.hasPrefix("com.apple.") { return parent }
        let name = descriptorURL.lastPathComponent.lowercased()
        if name.contains("video") || name.contains("photos") {
            return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        }
        if name.contains("mercury") { return "com.apple.MercuryPoster" }
        return "com.apple.WallpaperKit.CollectionsPoster"
    }
}
