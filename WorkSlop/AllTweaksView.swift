import SwiftUI

/// All Tweaks: one row per tweak group. Tapping a row opens that
/// group's tweak options as a plain list.
struct AllTweaksView: View {
    private let groups: [TweakGroup] = [
        TweakGroup(id: "Liquid Glass", icon: "sparkles",
                   footer: "Partial restore on iOS 26, Full backup → modify → restore on iOS 27 - the same split as desktop."),
        TweakGroup(id: "SpringBoard", icon: "square.grid.2x2", footer: nil),
        TweakGroup(id: "Daemons", icon: "gearshape.2",
                   footer: "Daemon toggles stage the same disabled-daemons list the desktop manages."),
        TweakGroup(id: "Recommended", icon: "star",
                   footer: "The desktop one-tap Recommended analytics set, as individual switches."),
        TweakGroup(id: "Apple Internal", icon: "hammer", footer: nil),
        TweakGroup(id: "PosterBoard", icon: "rectangle.on.rectangle", footer: nil),
        TweakGroup(id: "Custom Icons", icon: "app.dashed", footer: nil),
    ]

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                ForEach(groups) { group in
                    NavigationLink {
                        TweakListView(group: group)
                    } label: {
                        HStack {
                            Label {
                                Text(group.id)
                            } icon: {
                                RowIcon(name: group.icon)
                            }
                            Spacer()
                            Text("\(group.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("tweak-group-\(group.id)")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("All Tweaks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TweakGroup: Identifiable, Hashable {
    let id: String
    let icon: String
    let footer: String?

    /// The catalog section this row reads. The menu label stays
    /// user-facing ("Apple Internal"); the catalog calls it
    /// "Internal Options".
    var catalogSection: String {
        id == "Apple Internal" ? "Internal Options" : id
    }

    var count: Int {
        switch id {
        case "Custom Icons": return IOS18IconCatalog.tintedIcons.count + CustomIconStore.load().count
        case "PosterBoard": return FeatureCatalog.features(in: "PosterBoard").count
        default: return FeatureCatalog.features(in: catalogSection).count
        }
    }
}

/// The tweak options of one group: plain toggles, never sliders.
struct TweakListView: View {
    let group: TweakGroup
    // Shared app-wide stage (owned by ContentView): icons staged here
    // are visible to ApplyView's gate, so icons alone enable Apply.
    @EnvironmentObject private var iconStage: IconStage

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                if group.id == "Custom Icons" {
                    customIcons
                } else {
                    Section {
                        ForEach(FeatureCatalog.features(in: group.catalogSection)) { feature in
                            FeatureToggleRow(feature: feature)
                        }
                        if group.id == "PosterBoard" {
                            NavigationLink {
                                PosterBoardFilesView()
                            } label: {
                                Label {
                                    Text("PosterBoard files")
                                } icon: {
                                    RowIcon(name: "rectangle.on.rectangle")
                                }
                            }
                            .accessibilityIdentifier("nav-posterboard-files")
                        }
                    } footer: {
                        if let footer = group.footer { Text(footer) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(group.id)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Custom Icons (Your Icons + iOS 18 galleries)

    private var customIcons: some View {
        Group {
            YourIconsSection()
            Section {
                ForEach(IOS18IconCatalog.lightIcons) { icon in
                    GalleryRow(icon: icon, variant: .light)
                }
            } header: {
                Text("Light")
            }
            Section {
                ForEach(IOS18IconCatalog.darkIcons) { icon in
                    GalleryRow(icon: icon, variant: .dark)
                }
            } header: {
                Text("Dark")
            }
            Section {
                ForEach(IOS18IconCatalog.tintedIcons) { icon in
                    GalleryRow(icon: icon, variant: .tinted)
                }
            } header: {
                Text("Tinted")
            } footer: {
                Text("Official iOS 18 icon pack by catwithabaloon (v2.0), shipped byte-identical from WorkSlop Desktop v15.")
            }
        }
    }
}
