import SwiftUI

/// Search results drawn as rows, one per source catalog.
///
/// Android's search is a row model: every search-capable catalog keeps its own
/// row, and the raw item id is passed through to Details, so an episode result
/// is an episode and an "AI Episodes" catalog is a row rather than tiles mixed
/// into the title grid. tvOS flattened all of that into one grid, which erased
/// which catalog answered the query and made an episode indistinguishable from
/// its show.
///
/// Rows are ordered exactly as the repository queried them, so the first row is
/// the first source the user configured.
struct SearchResultsRails: View {
    let sections: [CatalogSearchSection]
    var people: [TmdbPersonMetadata] = []
    let onSelectItem: (NuvioMeta) -> Void
    var onFocusItem: ((NuvioMeta) -> Void)? = nil
    var onBlurItem: ((NuvioMeta) -> Void)? = nil
    var onLongPressItem: ((NuvioMeta) -> Void)? = nil
    var onSelectPerson: ((TmdbPersonMetadata) -> Void)? = nil
    /// Pins this row to Home as a saved search. Only an add-on row carries the
    /// add-on id and query that make that possible; the built-in rows do not.
    var onAddSectionToHome: ((CatalogSearchSection) -> Void)? = nil

    private let posterWidth: CGFloat = 210
    private let posterHeight: CGFloat = 315
    /// Episode results carry a landscape still. Keeping the poster frame would
    /// crop it to a strip; giving the card the still's own shape is what makes
    /// an episode read as an episode.
    private let landscapeWidth: CGFloat = 320
    private let landscapeHeight: CGFloat = 180
    private let cardSpacing: CGFloat = 28
    private let contentInset: CGFloat = 64

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                if !people.isEmpty, let onSelectPerson {
                    peopleRow(onSelectPerson)
                }
                ForEach(sections) { section in
                    resultsRow(section)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
    }

    private func resultsRow(_ section: CatalogSearchSection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                rowTitle(section.title)
                if section.addonId != nil, section.searchTerm != nil,
                   let onAddSectionToHome {
                    AddSearchRowButton(title: section.title) {
                        onAddSectionToHome(section)
                    }
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(section.results) { item in
                        let landscape = item.tileShape == .landscape || item.isEpisodeResult
                        PosterGridCard(
                            meta: item,
                            width: landscape ? landscapeWidth : posterWidth,
                            height: landscape ? landscapeHeight : posterHeight,
                            onFocus: onFocusItem,
                            onBlur: onBlurItem,
                            onLongPress: onLongPressItem.map { callback -> () -> Void in { callback(item) } },
                            forceShowLabels: true,
                            artworkURL: landscape ? item.backdropUrl : nil
                        ) {
                            onSelectItem(item)
                        }
                    }
                }
                .padding(.horizontal, contentInset)
            }
            .scrollClipDisabledIfAvailable()
        }
    }

    private func peopleRow(_ onSelect: @escaping (TmdbPersonMetadata) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            rowTitle(L10n.string("tvos_search_people_row", fallback: "People"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(people) { person in
                        PersonRailCard(person: person) { onSelect(person) }
                    }
                }
                .padding(.horizontal, contentInset)
            }
            .scrollClipDisabledIfAvailable()
        }
    }

    private func rowTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, contentInset)
    }
}

/// Pins a search row to Home. A visible control rather than a card long-press:
/// the card's hold-menu is built inside the card itself and cannot take an
/// extra item, so an action hidden there is an action nobody can reach.
private struct AddSearchRowButton: View {
    let title: String
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.rectangle")
                Text(L10n.string("search_add_row_to_home", fallback: "Add row to Home"))
            }
            .font(.system(size: 18, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white.opacity(focused ? 0.28 : 0.12), in: Capsule())
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .accessibilityLabel(
            Text("\(L10n.string("search_add_row_to_home", fallback: "Add row to Home")): \(title)")
        )
    }
}

/// A cast/crew member from `/search/person`, shown in the People row. Taps push
/// the app's existing `personBrowse` screen, so a searched actor lands on the
/// same filmography as one opened from a title's cast list.
private struct PersonRailCard: View {
    let person: TmdbPersonMetadata
    let action: () -> Void

    @FocusState private var focused: Bool
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true

    private let size: CGFloat = 170

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                CachedPosterArtwork(
                    urlString: person.profileURL,
                    width: size,
                    height: size,
                    maximumWidth: size,
                    minimumSwapDelay: 0
                ) {
                    placeholder
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        focused ? AppFocusOutline.color : Color.clear,
                        lineWidth: AppFocusOutline.width
                    )
                )
                .shadow(color: .black.opacity(focused ? 0.5 : 0.2), radius: focused ? 16 : 6)

                MarqueeText(
                    person.name,
                    size: 20,
                    weight: .semibold,
                    color: focused ? .white : .white.opacity(0.78),
                    isActive: focused
                )
                .frame(width: size)

                if let role = person.role {
                    Text(role)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                        .frame(width: size)
                }
            }
            .scaleEffect(focused ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle(onNativeFocusChange: { focused = $0 }))
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .animation(
            smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil,
            value: focused
        )
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Text(initials)
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private var initials: String {
        person.name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
    }
}
