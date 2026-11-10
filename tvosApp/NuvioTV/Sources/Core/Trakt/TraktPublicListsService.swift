import Foundation

/// One public Trakt list that contains the pressed title.
struct TraktPublicListSummary: Identifiable, Equatable {
    let id: Int
    let name: String
    let owner: String?
    let itemCount: Int?

    var displayTitle: String {
        guard let owner, !owner.isEmpty else { return name }
        return "\(name) · by \(owner)"
    }
}

enum TraktPublicListsError: LocalizedError, Equatable {
    case missingClientID
    case noImdbId
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter a Trakt Client ID in Settings to browse public lists."
        case .noImdbId:
            return "This title has no IMDb id, so it cannot be looked up on Trakt."
        case let .requestFailed(code):
            return "Trakt refused the request (\(code))."
        }
    }
}

/// The public-list lookup behind the tile menu's "Public Lists" screen — the
/// complement of the profile's own lists: "which of everybody's public lists
/// contain this title", answered live.
///
///     GET /movies/{imdb}/lists/personal/popular?extended=full&limit=N
///     GET /shows/{imdb}/lists/personal/popular?extended=full&limit=N
///
/// Both are public, so this only needs the Trakt Client ID — it works signed
/// out and on a local-only profile. The total is Trakt's own
/// `x-pagination-item-count`, not the page size, so the header can say how many
/// lists really exist.
///
/// Item fetches are sequential on purpose, exactly as Android's
/// `PublicListsViewModel` does: Trakt rate-limits per app, and a dozen parallel
/// row requests is how the screen earns a 429.
struct TraktPublicListsService {
    private let store: UserDefaults

    init(store: UserDefaults = ProfileSettings.current) {
        self.store = store
    }

    static var isConfigured: Bool {
        TraktConfig.isConfigured
    }

    func listsContaining(meta: NuvioMeta, limit: Int = 20) async throws -> (lists: [TraktPublicListSummary], total: Int) {
        let clientID = TraktConfig.clientID(in: store)
        guard !clientID.isEmpty else { throw TraktPublicListsError.missingClientID }
        guard let imdbId = Self.imdbId(for: meta) else { throw TraktPublicListsError.noImdbId }

        let isSeries = Self.isSeries(meta)
        var components = URLComponents(
            string: "\(TraktConfig.apiBaseURL)/\(isSeries ? "shows" : "movies")/\(imdbId)/lists/personal/popular"
        )!
        components.queryItems = [
            URLQueryItem(name: "extended", value: "full"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw TraktPublicListsError.requestFailed(0) }

        let (data, http) = try await Self.get(url, clientID: clientID)
        guard 200..<300 ~= http.statusCode else {
            throw TraktPublicListsError.requestFailed(http.statusCode)
        }
        let decoded = (try? JSONDecoder().decode([TraktPublicListDTO].self, from: data)) ?? []
        let lists = decoded.compactMap { dto -> TraktPublicListSummary? in
            guard let listId = dto.ids?.trakt,
                  let name = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return TraktPublicListSummary(
                id: listId,
                name: name,
                owner: dto.user?.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                itemCount: dto.itemCount
            )
        }
        let total = http.value(forHTTPHeaderField: "x-pagination-item-count")
            .flatMap(Int.init) ?? lists.count
        return (lists, total)
    }

    func items(in list: TraktPublicListSummary, matching meta: NuvioMeta, limit: Int = 20) async throws -> [NuvioMeta] {
        let clientID = TraktConfig.clientID(in: store)
        guard !clientID.isEmpty else { throw TraktPublicListsError.missingClientID }
        let isSeries = Self.isSeries(meta)
        var components = URLComponents(
            string: "\(TraktConfig.apiBaseURL)/lists/\(list.id)/items/\(isSeries ? "show" : "movie")"
        )!
        components.queryItems = [
            URLQueryItem(name: "extended", value: "full,images"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw TraktPublicListsError.requestFailed(0) }

        let (data, http) = try await Self.get(url, clientID: clientID)
        guard 200..<300 ~= http.statusCode else {
            throw TraktPublicListsError.requestFailed(http.statusCode)
        }
        let decoded = (try? JSONDecoder().decode([TraktPublicListItemDTO].self, from: data)) ?? []
        var seen = Set<String>()
        return decoded.compactMap { entry in
            Self.meta(
                from: isSeries ? entry.show : entry.movie,
                type: isSeries ? "series" : "movie"
            )
        }
        .filter { seen.insert("\($0.type):\($0.id)").inserted }
    }

    // MARK: - Transport

    private static func get(_ url: URL, clientID: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue(TraktConfig.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TraktPublicListsError.requestFailed(0)
        }
        return (data, http)
    }

    // MARK: - Mapping

    private static func imdbId(for meta: NuvioMeta) -> String? {
        [meta.imdbId, meta.id]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.range(of: "^tt\\d+$", options: .regularExpression) != nil }
    }

    private static func isSeries(_ meta: NuvioMeta) -> Bool {
        meta.type.caseInsensitiveCompare("movie") != .orderedSame
    }

    private static func meta(from media: TraktPublicListMedia?, type: String) -> NuvioMeta? {
        guard let media else { return nil }
        let imdb = media.ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines)
        let traktId = media.ids?.trakt
        let id: String
        if let imdb, !imdb.isEmpty {
            id = imdb
        } else if let traktId {
            id = "trakt:\(traktId)"
        } else {
            return nil
        }
        let title = (media.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let year = media.year.flatMap { $0 > 0 ? $0 : nil }
        return NuvioMeta(
            id: id,
            name: title,
            description: media.overview,
            posterUrl: traktImage(media.images?.poster) ?? traktImage(media.images?.fanart),
            backgroundUrl: traktImage(media.images?.fanart) ?? traktImage(media.images?.thumb),
            logoUrl: traktImage(media.images?.logo),
            imdbId: (imdb?.isEmpty == false) ? imdb : nil,
            tmdbId: media.ids?.tmdb,
            type: type,
            year: year,
            genres: media.genres,
            rating: media.rating.flatMap { $0 > 0 ? $0 : nil },
            releaseInfo: year.map(String.init) ?? media.released,
            runtime: media.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
            cast: nil,
            director: nil,
            writer: nil,
            certification: media.certification,
            country: media.country,
            language: nil,
            released: media.released ?? media.firstAired,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil,
            posterShape: nil,
            isFromAddon: nil,
            landscapePosterUrl: nil
        )
    }

    private static func traktImage(_ values: [String]?) -> String? {
        guard var value = values?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if value.hasPrefix("//") {
            value = "https:\(value)"
        } else if value.lowercased().hasPrefix("http://") {
            value = "https://" + String(value.dropFirst("http://".count))
        } else if !value.lowercased().hasPrefix("https://") {
            value = "https://\(value)"
        }
        return value
    }
}

// MARK: - Wire types

private struct TraktPublicListDTO: Decodable {
    let name: String?
    let ids: Ids?
    let user: User?
    let itemCount: Int?

    enum CodingKeys: String, CodingKey {
        case name, ids, user
        case itemCount = "item_count"
    }

    struct Ids: Decodable { let trakt: Int? }
    struct User: Decodable { let username: String? }
}

private struct TraktPublicListItemDTO: Decodable {
    let movie: TraktPublicListMedia?
    let show: TraktPublicListMedia?
}

private struct TraktPublicListMedia: Decodable {
    let title: String?
    let year: Int?
    let ids: Ids?
    let overview: String?
    let released: String?
    let firstAired: String?
    let rating: Double?
    let genres: [String]?
    let runtime: Int?
    let certification: String?
    let country: String?
    let images: Images?

    enum CodingKeys: String, CodingKey {
        case title, year, ids, overview, released, rating, genres, runtime, certification, country, images
        case firstAired = "first_aired"
    }

    struct Ids: Decodable {
        let trakt: Int?
        let imdb: String?
        let tmdb: Int?
    }

    struct Images: Decodable {
        let poster: [String]?
        let fanart: [String]?
        let thumb: [String]?
        let logo: [String]?
    }
}
