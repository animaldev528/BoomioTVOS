import SwiftUI

/// The long-press menu's "More like this" destination: the same related titles
/// the Details screen draws as a rail, on a screen of their own, so a viewer
/// can move through recommendations without opening the title first.
struct MoreLikeThisView: View {
    let meta: NuvioMeta
    let onSelect: (String, String) -> Void

    @State private var items: [NuvioMeta] = []
    @State private var isLoading = true
    @FocusState private var focusedCardID: String?

    private let rowID = "more-like-this"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(meta.name)
                    .font(.appFont(size: 26, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                    .lineLimit(1)
                    .padding(.leading, TVLayout.rowLeading)

                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 48)
                } else if items.isEmpty {
                    Text(L10n.string("more_like_this_empty", fallback: "Nothing related found"))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.leading, TVLayout.rowLeading)
                        .padding(.top, 24)
                } else {
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
    }

    private var firstFocusID: String? {
        guard let item = items.first else { return nil }
        return TVHomeCardIdentity.key(rowID: rowID, item: item)
    }

    private func load() async {
        guard items.isEmpty else { return }
        isLoading = true
        let related = await TmdbDetailsService.fetchMoreLikeThis(for: meta, limit: 24)
        // Clear the spinner even when the fetch was cancelled: a view that
        // outlives its task must not sit on an empty screen spinning forever.
        isLoading = false
        guard !Task.isCancelled else { return }
        items = TitleFeedbackStore.visible(related.map(\.asMeta))
    }
}
