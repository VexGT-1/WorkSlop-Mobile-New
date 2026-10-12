import SwiftUI
import UniformTypeIdentifiers

/// Import-first PosterBoard file management: the user brings .tendies
/// (or .batter template) files; the modes stage them for the engine.
/// Plain table, no animation behind the content.
struct PosterBoardFilesView: View {
    @State private var importing = false
    @State private var note: String?
    @State private var files: [String] = TendiesStore.list(kind: "Tendies")
    @State private var templateFiles: [String] = TendiesStore.list(kind: "Templates")
    /// Which table the single importer serves. One importer only: two
    /// .fileImporter modifiers on one view conflict.
    @State private var importKind = "Tendies"

    var body: some View {
        List {
            Section {
                Button("Import PosterBoard file (.tendies)") { importKind = "Tendies"; importing = true }
                    .accessibilityIdentifier("pb-import")
                if files.isEmpty {
                    Text("Nothing imported. PosterBoard delivers nothing until at least one .tendies is here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files, id: \.self) { name in
                        Label(name, systemImage: "doc")
                            .font(.footnote)
                    }
                    .onDelete { offsets in
                        TendiesStore.delete(at: offsets, from: files, kind: "Tendies")
                        files = TendiesStore.list(kind: "Tendies")
                    }
                }
            } header: {
                Text("PosterBoard (.tendies)")
            } footer: {
                Text("Up to 5 files ride one apply (desktop cap).")
            }

            Section {
                Button("Import Template file (.batter)") { importKind = "Templates"; importing = true }
                    .accessibilityIdentifier("themes-template-import")
                if templateFiles.isEmpty {
                    Text("Nothing imported. Templates install and manage delivered PosterBoard content the desktop way.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(templateFiles, id: \.self) { name in
                        Label(name, systemImage: "doc")
                            .font(.footnote)
                    }
                    .onDelete { offsets in
                        TendiesStore.delete(at: offsets, from: templateFiles, kind: "Templates")
                        templateFiles = TendiesStore.list(kind: "Templates")
                    }
                }
            } header: {
                Text("Templates (.batter)")
            } footer: {
                Text("Template packages manage delivered PosterBoard content. (The database/Configurations side exists on desktop and is not offered on mobile.)")
            }

            if let note {
                Section {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PosterBoard Files")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: importKind == "Tendies" ? "tendies" : "batter") ?? .data],
                      allowsMultipleSelection: true) { result in
            let kind = importKind
            let ext = kind == "Tendies" ? "tendies" : "batter"
            switch result {
            case .success(let urls):
                var imported = 0
                for url in urls {
                    guard url.pathExtension.lowercased() == ext else { continue }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if TendiesStore.save(url: url, kind: kind) { imported += 1 }
                }
                files = TendiesStore.list(kind: "Tendies")
                templateFiles = TendiesStore.list(kind: "Templates")
                note = imported > 0
                    ? "Imported \(imported) .\(ext) file(s) into \(kind). Staged for the next engine apply."
                    : "Nothing imported - this table takes .\(ext) only."
            case .failure:
                note = "Import cancelled."
            }
        }
    }
}

// MARK: - Tendies store (PosterBoard imports)

enum TendiesStore {
    static func dir(kind: String) -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kind, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func list(kind: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir(kind: kind).path))?.sorted() ?? []
    }

    static func save(url: URL, kind: String) -> Bool {
        // No import-time cap: desktop caps .tendies at 5 per
        // restore, at apply time - imports are never refused,
        // and templates are not capped at all.
        let dest = dir(kind: kind).appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return true
        } catch {
            return false
        }
    }

    static func delete(at offsets: IndexSet, from files: [String], kind: String) {
        for i in offsets {
            try? FileManager.default.removeItem(at: dir(kind: kind).appendingPathComponent(files[i]))
        }
    }
}
