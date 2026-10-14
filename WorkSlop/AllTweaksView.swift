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
        TweakGroup(id: "AirFlit", icon: "creditcard",
                   footer: "Passcode themes + Wallet card images via the AirCard method (AirTraffic). iOS 18.0 – 27.2 beta 2 only."),
    ]

    var body: some View {
        ZStack {
            SkyBackground()
            List {
                ForEach(groups) { group in
                    NavigationLink {
                        if group.id == "AirFlit" {
                            AirFlitView()
                        } else {
                            TweakListView(group: group)
                        }
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
        case "AirFlit": return 2 // Passcode Theme + Wallet Image
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

    private func selectAll(variant: IconVariant) {
        for icon in IOS18IconCatalog.icons(for: variant) {
            guard let data = galleryDataFor(icon: icon, variant: variant) else { continue }
            iconStage.stage(CustomIconEntry(bundleID: icon.bundleID, appName: icon.name, imageData: data))
        }
    }

    private func galleryDataFor(icon: IOS18Icon, variant: IconVariant) -> Data? {
        switch variant {
        case .light: return IOS18IconCatalog.imageData(slug: icon.slug, dark: false)
        case .dark: return IOS18IconCatalog.imageData(slug: icon.slug, dark: true)
        case .tinted: return IOS18IconCatalog.tintedImageData(slug: icon.slug)
        default: return IOS18IconCatalog.variantImageData(variant, slug: icon.slug)
        }
    }

    private func gallerySection(variant: IconVariant) -> some View {
        Section {
            ForEach(IOS18IconCatalog.icons(for: variant)) { icon in
                GalleryRow(icon: icon, variant: variant)
            }
        } header: {
            HStack {
                Text(variant.title)
                Spacer()
                Button("Select All") {
                    selectAll(variant: variant)
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
    }

    private var customIcons: some View {
        Group {
            YourIconsSection()
            gallerySection(variant: .light)
            gallerySection(variant: .dark)
            Section {
                ForEach(IOS18IconCatalog.tintedIcons) { icon in
                    GalleryRow(icon: icon, variant: .tinted)
                }
            } header: {
                HStack {
                    Text("Tinted")
                    Spacer()
                    Button("Select All") {
                        for icon in IOS18IconCatalog.tintedIcons {
                            guard let data = IOS18IconCatalog.tintedImageData(slug: icon.slug) else { continue }
                            iconStage.stage(CustomIconEntry(bundleID: icon.bundleID, appName: icon.name, imageData: data))
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            } footer: {
                Text("Official iOS 18 icon pack by catwithabaloon (v2.0), shipped byte-identical from WorkSlop Desktop v15.")
            }
            gallerySection(variant: .tintedGreen)
            gallerySection(variant: .tintedYellow)
            gallerySection(variant: .tintedBlue)
            gallerySection(variant: .tintedWhite)
            gallerySection(variant: .tintedGray)
            gallerySection(variant: .tintedBrown)
            gallerySection(variant: .tintedCream)
        }
    }
}
