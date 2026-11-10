import SwiftUI

/// The long-press menu's "More like this" destination: the same related titles
/// the Details screen draws as a rail, on a screen of their own, so a viewer
/// can move through recommendations without opening the title first.
///
/// The Back control is a real focusable element and the Menu press is handled
/// here. A screen whose only content is an empty message has nothing focusable,
/// and on tvOS a Menu press with no focused responder leaves the app instead of
/// dismissing it — which strands a viewer whose remote has no touch surface.
struct MoreLikeThisView: View {
    let meta: NuvioMeta
    let onSelect: (String, String) -> Void
    let onBack: () -> Void

    @State private var items: [NuvioMeta] = []
    /// The thematic lists the title was matched on ("1930s · 2010s · lgbt") —
    /// the taste add-on's own explanation of why these titles are related.
    @State private var caption: String?
    @State private var isLoading = true
    @State private var attempted = false
    @FocusState private var focusedCardID: String?
    @FocusState private var backFocused: Bool

    private let rowID = "more-like-this"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 48)
                } else if items.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.leading, TVLayout.rowLeading)
                        .padding(.top, 24)
                } else {
                    if let caption {
                        Text(caption)
                            .font(.appFont(size: 20))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(2)
                            .padding(.leading, TVLayout.rowLeading)
                            .padding(.bottom, 6)
                    }
                    TVCatalogRow(
                        id: rowID,
                        title: L10n.string("details_more_like_this", fallback: "More like this"),
                        showsSectionTitle: true,
                        horizontalEdgeInset: 0,
                        items: items,
                        initialFocusCardKey: nil,
                        landscapeFocusedId: nil,
                        externalFocus: $focusedCardID,
                        onInitialFocusRequested: {},
                        onFocus: { item in
                            focusedCardID = TVHomeCardIdentity.key(rowID: rowID, item: item)
                        },
                        onBlur: { _ in },
                        onApproachEnd: { _ in },
                        onSelect: { item in
                            onSelect(item.id, item.type)
                        }
                    )
                    .id(rowID)
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 80)
        }
        .focusSection()
        .defaultFocusIfAvailable($focusedCardID, firstFocusID)
        .task { await load() }
        .onChange(of: isLoading) { _, loading in
            // With no row to focus, focus has to land on Back or the Menu press
            // has no responder.
            if !loading && items.isEmpty { backFocused = true }
        }
        .onExitCommand(perform: onBack)
    }

    private var header: some View {
        HStack(spacing: 20) {
            Button(action: onBack) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                    Text(L10n.string("back", fallback: "Back"))
                }
                .font(.appFont(size: 18, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Color.white.opacity(backFocused ? 0.24 : 0.12),
                    in: Capsule()
                )
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .focused($backFocused)

            Text(meta.name)
                .font(.appFont(size: 26, weight: .semibold))
                .foregroundColor(.white.opacity(0.86))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, TVLayout.rowLeading)
    }

    private var emptyMessage: String {
        // The profile's own curated rows know best; TMDB only answers when the
        // profile has no curated-row add-on. Say which one is missing.
        if TasteMoreLikeThisService.rowAddonBaseURL == nil && !TmdbDetailsService.isConfigured {
            return L10n.string(
                "more_like_this_needs_tmdb",
                fallback: "Enable TMDB in Settings to see related titles"
            )
        }
        return L10n.string("more_like_this_empty", fallback: "Nothing related found")
    }

    private var firstFocusID: String? {
        guard let item = items.first else { return nil }
        return TVHomeCardIdentity.key(rowID: rowID, item: item)
    }

    private func load() async {
        guard !attempted else { return }
        attempted = true
        isLoading = true
        // The taste add-on first: it answers from this profile's curated
        // universe, which is what the Android wall shows. TMDB is only the
        // fallback for a profile with no curated rows installed.
        let curated = await TasteMoreLikeThisService().fetch(meta: meta)
        // Clear the spinner even when the fetch was cancelled: a view that
        // outlives its task must not sit on an empty screen spinning forever.
        isLoading = false
        guard !Task.isCancelled else { return }
        if let curated, !curated.items.isEmpty {
            caption = curated.caption
            items = TitleFeedbackStore.visible(curated.items)
            return
        }
        let related = await TmdbDetailsService.fetchMoreLikeThis(for: meta, limit: 24)
        guard !Task.isCancelled else { return }
        items = TitleFeedbackStore.visible(related.map(\.asMeta))
    }
}
