import Foundation

/// The taste add-on's "More like this" wall — the one the Android client
/// opens from a tile's long-press menu.
///
/// The add-on answers per profile from the same curated document its rows come
/// from:
///
///     {rowBase}/more-like-this/{movie|series}/{ttId}.json?skip=N[&exclude=tt…]
///
/// and returns the thematic lists the pressed title belongs to (the
/// "1930s · 2010s · lgbt" caption) plus one page of the other approved titles
/// on them. That is a different answer from TMDB's recommendations: it is
/// scoped to this profile's universe, which is why the Apple TV wall was empty
/// where the Android one was full.
///
/// Page size is 25, and `hasMore` is "a full page came back" — the add-on does
/// not report a total.
struct TasteMoreLikeThisPage {
    let caption: String?
    let items: [NuvioMeta]
    let hasMore: Bool
}

struct TasteMoreLikeThisService {
    static let pageSize = 25

    private let repository: CinemetaCatalogRepository

    init(repository: CinemetaCatalogRepository = CinemetaCatalogRepository()) {
        self.repository = repository
    }

    /// The installed add-on that serves this profile's curated rows. Android
    /// finds it by its `/row/` base path (`curatedRowAddonFor`), so the same
    /// marker is used here rather than a hard-coded host.
    static var rowAddonBaseURL: URL? {
        let manifests = CinemetaCatalogRepository.configuredStreamAddonManifestURLs
        guard let manifest = manifests.first(where: { $0.absoluteString.contains("/row/") }) else {
            return nil
        }
        let base = manifest.lastPathComponent.lowercased() == "manifest.json"
            ? manifest.deletingLastPathComponent()
            : manifest
        return TasteMoreLikeThisService.baseWithoutQuery(base)
    }

    /// `nil` when this profile has no curated-row add-on, or when the title has
    /// no IMDb id — the endpoint is keyed by `tt`, and answering about a
    /// guessed id would be a different title's wall.
    func fetch(meta: NuvioMeta, skip: Int = 0, exclude: [String] = []) async -> TasteMoreLikeThisPage? {
        guard let base = Self.rowAddonBaseURL,
              let imdbId = Self.imdbId(for: meta),
              let url = Self.url(base: base, type: Self.apiType(for: meta), imdbId: imdbId, skip: skip, exclude: exclude)
        else { return nil }

        guard let response: TasteMoreLikeThisResponse = try? await repository.fetch(url) else {
            return nil
        }
        let items = (response.metas ?? [])
            .map { $0.toMeta(fallbackType: Self.localType(for: meta)) }
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var seen = Set<String>()
        let unique = items.filter { seen.insert("\($0.type):\($0.id)").inserted }
        let names = (response.lists ?? [])
            .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return TasteMoreLikeThisPage(
            caption: names.isEmpty ? nil : names.joined(separator: " · "),
            items: unique,
            hasMore: unique.count >= Self.pageSize
        )
    }

    // MARK: - URL

    private static func url(
        base: URL,
        type: String,
        imdbId: String,
        skip: Int,
        exclude: [String]
    ) -> URL? {
        var url = base
            .appendingPathComponent("more-like-this")
            .appendingPathComponent(type)
            .appendingPathComponent("\(imdbId).json")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query = [URLQueryItem(name: "skip", value: String(skip))]
        let excluded = exclude
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !excluded.isEmpty {
            query.append(URLQueryItem(name: "exclude", value: excluded.joined(separator: ",")))
        }
        components.queryItems = (components.queryItems ?? []) + query
        url = components.url ?? url
        return url
    }

    private static func baseWithoutQuery(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query != nil || components.fragment != nil else { return url }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    // MARK: - Identity

    private static func imdbId(for meta: NuvioMeta) -> String? {
        let candidates = [meta.imdbId, meta.id]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.range(of: "^tt\\d+$", options: .regularExpression) != nil }
    }

    /// Server-facing media type: `movie`, or `series` for everything else
    /// (tv/anime presses are series, exactly as Android's `normalizedType`).
    private static func apiType(for meta: NuvioMeta) -> String {
        meta.type.caseInsensitiveCompare("movie") == .orderedSame ? "movie" : "series"
    }

    private static func localType(for meta: NuvioMeta) -> String {
        apiType(for: meta) == "movie" ? "movie" : "series"
    }
}

private struct TasteMoreLikeThisResponse: Decodable {
    let lists: [TasteMoreLikeThisList]?
    let metas: [CinemetaMeta]?
}

private struct TasteMoreLikeThisList: Decodable {
    let key: String?
    let kind: String?
    let name: String?
    let count: Int?
}
