import SwiftUI

/// Movies / TV / Anime — the three browse destinations the Android client has
/// and upstream NuvioTVOS does not.
///
/// Each add-on `hub-*` catalog is a section; its drilldown
/// (`rec-<id>-drilldown`) names the sub-row catalogs the section draws, so
/// "By Genre" is followed by the genres themselves rather than one flat grid.
/// A section with no drill falls back to the hub catalog's own content, and a
/// section that produces no row is dropped instead of shipped blank — the same
/// rules as Android's `HubBrowseScreen`.
struct HubBrowseView: View {
    let kind: TVHubKind
    let isActive: Bool
    let onNavigateToDetails: (String, String) -> Void
    let onLongPressCard: (NuvioMeta) -> Void

    @StateObject private var model: HubBrowseViewModel
    @FocusState private var focusedCardID: String?
    /// Which hub section the ribbon has selected. `nil` until the user moves
    /// through the ribbon, which means "the first one".
    @State private var selectedSectionID: String?
    @FocusState private var focusedTabID: String?

    init(
        kind: TVHubKind,
        isActive: Bool,
        onNavigateToDetails: @escaping (String, String) -> Void,
        onLongPressCard: @escaping (NuvioMeta) -> Void,
        repository: CinemetaCatalogRepository = CinemetaCatalogRepository()
    ) {
        self.kind = kind
        self.isActive = isActive
        self.onNavigateToDetails = onNavigateToDetails
        self.onLongPressCard = onLongPressCard
        _model = StateObject(wrappedValue: HubBrowseViewModel(kind: kind, repository: repository))
    }

    var body: some View {
        Group {
            if isActive {
                content
            } else {
                Color.clear
            }
        }
        .onAppear {
            if isActive { model.loadIfNeeded() }
        }
        .onChange(of: isActive) { _, active in
            if active {
                model.loadIfNeeded()
            } else {
                model.cancel()
            }
        }
        // "Not interested" is recorded locally, so the row has to re-read its
        // items when the signal changes or the tile it just dismissed stays.
        .onReceive(NotificationCenter.default.publisher(for: TitleFeedbackStore.changedNotification)) { _ in
            model.applyFeedbackFilter()
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if showsRibbon {
                    ribbon
                }
                if let section = activeSection {
                    sectionView(section, showsTitle: !showsRibbon)
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 80)
        }
        .focusSection()
        .defaultFocusIfAvailable($focusedCardID, firstFocusID)
        .overlay { stateOverlay }
    }

    /// Android's hub ribbon (`HubBrowseScreen.kt`): one tab per hub section,
    /// selection follows tab focus, and only the selected section's rows are
    /// drawn. A hub with a single section has no ribbon — the tab would be the
    /// whole screen.
    private var showsRibbon: Bool {
        model.sections.count > 1
    }

    private var activeSection: TVHubSection? {
        if let selectedSectionID,
           let match = model.sections.first(where: { $0.id == selectedSectionID }) {
            return match
        }
        return model.sections.first
    }

    private var ribbon: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(model.sections) { section in
                    let isSelected = activeSection?.id == section.id
                    Button {
                        selectedSectionID = section.id
                    } label: {
                        Text(section.title)
                            .font(.appFont(size: 20, weight: .semibold))
                            .foregroundColor(.white.opacity(isSelected ? 0.95 : 0.6))
                            .lineLimit(1)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                Color.white.opacity(isSelected ? 0.18 : 0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedTabID, equals: section.id)
                }
            }
            .padding(.horizontal, TVLayout.rowLeading)
            .padding(.vertical, 6)
        }
        // Only the ribbon scrolls sideways; Up from the rows has to reach it.
        .focusSection()
        .onChange(of: focusedTabID) { _, id in
            guard let id, id != selectedSectionID else { return }
            selectedSectionID = id
        }
    }

    private func sectionView(_ section: TVHubSection, showsTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsTitle {
                Text(section.title)
                    .font(.appFont(size: 26, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                    .lineLimit(1)
                    .padding(.leading, TVLayout.rowLeading)
            }

            ForEach(section.rows) { row in
                TVCatalogRow(
                    id: row.id,
                    title: row.title,
                    addonName: row.addonName,
                    showsSectionTitle: true,
                    horizontalEdgeInset: 0,
                    items: row.items,
                    initialFocusCardKey: nil,
                    landscapeFocusedId: nil,
                    externalFocus: $focusedCardID,
                    onInitialFocusRequested: {},
                    onFocus: { meta in
                        focusedCardID = TVHomeCardIdentity.key(rowID: row.id, item: meta)
                    },
                    onBlur: { _ in },
                    onApproachEnd: { _ in },
                    onSelect: { meta in
                        onNavigateToDetails(meta.id, meta.type)
                    },
                    onLongPress: onLongPressCard
                )
                .id(row.id)
            }
        }
    }

    private var firstFocusID: String? {
        guard let row = activeSection?.rows.first(where: { !$0.items.isEmpty }),
              let item = row.items.first else { return nil }
        return TVHomeCardIdentity.key(rowID: row.id, item: item)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if model.sections.isEmpty {
            if model.isLoading {
                ProgressView()
                    .tint(.white)
            } else if model.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.minus")
                        .font(.system(size: 48, weight: .light))
                        .foregroundColor(.white.opacity(0.4))
                    Text(L10n.string("hub_empty_title", fallback: "Nothing here yet"))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                    Text(L10n.string(
                        "hub_empty_subtitle",
                        fallback: "Enable a catalog addon to populate this hub"
                    ))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }
}
