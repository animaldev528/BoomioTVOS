import SwiftUI

/// The tile long-press menu's "Public Lists": every public Trakt list that
/// contains the pressed title, one row of posters per list.
///
/// This is the Android screen (`PublicListsScreen.kt`), not the collection
/// editor's URL picker: the lists are discovered from the title itself, so a
/// viewer never has to know a list's address to see what other people filed it
/// under.
///
/// Rows arrive one at a time — each row is its own Trakt request, and they go
/// out sequentially for the rate limit — so the first rows are readable while
/// the rest are still loading.
struct PublicListsView: View {
    let meta: NuvioMeta
    let onSelect: (String, String) -> Void
    let onBack: () -> Void
    let onAddListToHome: () -> Void

    @StateObject private var model: PublicListsViewModel
    @State private var rows: [TVHubSectionRow] = []
    @State private var total = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @FocusState private var focusedCardID: String?
    @FocusState private var backFocused: Bool
    /// The list behind each row, so holding a card can offer to pin that very
    /// list instead of making the viewer find it again in the picker.
    @State private var listByRowID: [String: TraktPublicListSummary] = [:]
    /// The add-to-Home panel. The card's hold-menu is built inside
    /// `PosterCard` and cannot take an extra item, so the action gets its own
    /// focusable panel instead of a gesture that would never reach it.
    @State private var showAddPicker = false
    @FocusState private var pickerFocusID: String?

    init(
        meta: NuvioMeta,
        onSelect: @escaping (String, String) -> Void,
        onBack: @escaping () -> Void,
        onAddListToHome: @escaping () -> Void,
        service: TraktPublicListsService = TraktPublicListsService()
    ) {
        self.meta = meta
        self.onSelect = onSelect
        self.onBack = onBack
        self.onAddListToHome = onAddListToHome
        _model = StateObject(wrappedValue: PublicListsViewModel(meta: meta, service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header

                if isLoading && rows.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 48)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.appFont(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.leading, TVLayout.rowLeading)
                } else if rows.isEmpty {
                    Text(L10n.string(
                        "public_lists_empty",
                        fallback: "No public Trakt lists include this title"
                    ))
                    .font(.appFont(size: 22))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.leading, TVLayout.rowLeading)
                } else {
                    ForEach(rows) { row in
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
                            onFocus: { item in
                                focusedCardID = TVHomeCardIdentity.key(rowID: row.id, item: item)
                            },
                            onBlur: { _ in },
                            onApproachEnd: { _ in },
                            onSelect: { item in
                                onSelect(item.id, item.type)
                            },
                            onLongPress: nil
                        )
                        .id(row.id)
                    }
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 80)
        }
        .focusSection()
        .defaultFocusIfAvailable($focusedCardID, firstFocusID)
        .task {
            await model.load { update in
                switch update {
                case let .lists(count):
                    total = count
                case let .row(row, list):
                    listByRowID[row.id] = list
                    rows.append(row)
                case let .finished:
                    isLoading = false
                case let .failed(message):
                    errorMessage = message
                    isLoading = false
                }
            }
        }
        .onChange(of: isLoading) { _, loading in
            // No row and no error leaves nothing focusable; Menu then has no
            // responder and tvOS leaves the app instead of dismissing.
            if !loading && rows.isEmpty { backFocused = true }
        }
        .onExitCommand(perform: onBack)
        .overlay { if showAddPicker { addPicker } }
    }

    /// The lists this title was found in, each one a press away from Home.
    /// Falls back to the full picker when nothing has loaded yet, so the header
    /// button is never a dead end.
    private var addPicker: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                Text(L10n.string(
                    "public_lists_add_confirm_title",
                    fallback: "Add this list to Home"
                ))
                .font(.appFont(size: 34, weight: .bold))
                .foregroundColor(.white)

                if rows.isEmpty {
                    Text(L10n.string(
                        "public_lists_empty",
                        fallback: "No public Trakt lists include this title"
                    ))
                    .font(.appFont(size: 22))
                    .foregroundColor(.white.opacity(0.6))
                    Button(action: onAddListToHome) {
                        Text(L10n.string("public_lists_add_to_home", fallback: "Add a list to Home"))
                            .font(.appFont(size: 20, weight: .semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.14), in: Capsule())
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(rows) { row in
                                if let list = listByRowID[row.id] {
                                    Button {
                                        addToHome(list)
                                        showAddPicker = false
                                    } label: {
                                        HStack(spacing: 16) {
                                            Text(list.displayTitle)
                                                .font(.appFont(size: 22, weight: .semibold))
                                            Spacer(minLength: 0)
                                            Image(systemName: "plus.rectangle.on.rectangle")
                                                .font(.appFont(size: 20))
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 16)
                                        .background(
                                            Color.white.opacity(pickerFocusID == row.id ? 0.26 : 0.10),
                                            in: RoundedRectangle(cornerRadius: 14)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .focused($pickerFocusID, equals: row.id)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                }

                Button {
                    showAddPicker = false
                } label: {
                    Text(L10n.string("action_cancel", fallback: "Cancel"))
                        .font(.appFont(size: 20, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.10), in: Capsule())
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(64)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
        .onAppear { pickerFocusID = rows.first?.id }
        .onExitCommand { showAddPicker = false }
    }

    /// The same `provider: trakt` source the collections editor writes, so the
    /// pinned shelf is indistinguishable from one built by hand.
    private func addToHome(_ list: TraktPublicListSummary) {
        let listId = Int64(list.id)
        let source: [String: Any] = [
            "provider": "trakt",
            "title": list.displayTitle,
            "traktListId": listId,
            "trakt_list_id": listId,
            "mediaType": "all",
            "media_type": "all",
            "sortBy": "rank",
            "sortHow": "asc"
        ]
        CollectionQuickAdd.addList(source: source, fallbackTitle: list.displayTitle)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
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

                Text(L10n.string("public_lists_title", fallback: "Public Lists"))
                    .font(.appFont(size: 34, weight: .bold))
                    .foregroundColor(.white)

                Spacer(minLength: 0)

                Button(action: { showAddPicker = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.rectangle.on.rectangle")
                        Text(L10n.string(
                            "public_lists_add_to_home",
                            fallback: "Add a list to Home"
                        ))
                    }
                    .font(.appFont(size: 18, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }

            Text(subtitle)
                .font(.appFont(size: 20))
                .foregroundColor(.white.opacity(0.55))
                .padding(.leading, 4)
        }
        .padding(.leading, TVLayout.rowLeading)
        .padding(.trailing, TVLayout.rowLeading)
    }

    private var subtitle: String {
        let title = meta.name
        let hint = L10n.string(
            "public_lists_hold_hint",
            fallback: "press Add a list to Home to pin one of these lists"
        )
        guard total > 0 else { return "\(title) · \(hint)" }
        let count = total == 1 ? "1 public list includes this title" : "\(total) public lists include this title"
        return "\(title) · \(count) · \(hint)"
    }

    private var firstFocusID: String? {
        guard let row = rows.first(where: { !$0.items.isEmpty }),
              let item = row.items.first else { return nil }
        return TVHomeCardIdentity.key(rowID: row.id, item: item)
    }
}

@MainActor
final class PublicListsViewModel: ObservableObject {
    enum Update {
        case lists(Int)
        case row(TVHubSectionRow, TraktPublicListSummary)
        case finished
        case failed(String)
    }

    private let meta: NuvioMeta
    private let service: TraktPublicListsService
    /// Rows are capped: every row is a Trakt request, and nobody pages through
    /// twenty of them. The header still reports Trakt's own total.
    private let rowLimit = 12

    init(meta: NuvioMeta, service: TraktPublicListsService) {
        self.meta = meta
        self.service = service
    }

    func load(_ emit: @escaping (Update) -> Void) async {
        do {
            let result = try await service.listsContaining(meta: meta)
            guard !Task.isCancelled else { return }
            emit(.lists(result.total))
            let visibleLists = Array(result.lists.prefix(rowLimit))
            for list in visibleLists {
                guard !Task.isCancelled else { return }
                let items = (try? await service.items(in: list, matching: meta)) ?? []
                guard !Task.isCancelled else { return }
                let visible = TitleFeedbackStore.visible(items)
                guard !visible.isEmpty else { continue }
                emit(.row(TVHubSectionRow(
                    id: "trakt-list-\(list.id)",
                    title: list.displayTitle,
                    catalogId: "trakt-list-\(list.id)",
                    items: visible,
                    addonName: L10n.string("public_lists_source", fallback: "from Trakt")
                ), list))
            }
            emit(.finished)
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }
}
