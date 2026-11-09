import Foundation

/// The left-menu destinations the Android client has and upstream NuvioTVOS
/// does not: Movies, TV and Anime each browse the configured add-ons' `hub-*`
/// catalogs. Ported from `HubKind` in the Android client
/// (`ui/screens/hub/HubBrowseViewModel.kt`).
enum TVHubKind: String, CaseIterable, Identifiable {
    case movies
    case tv
    case anime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return L10n.string("nav_movies", fallback: "Movies")
        case .tv: return L10n.string("nav_tv", fallback: "TV")
        case .anime: return L10n.string("nav_anime", fallback: "Anime")
        }
    }

    var symbol: String {
        switch self {
        case .movies: return "film"
        case .tv: return "tv"
        case .anime: return "sparkles"
        }
    }
}
