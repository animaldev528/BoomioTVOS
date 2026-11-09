import Foundation

/// Creates a Home collection from whatever the user is already looking at —
/// an actor, a public Trakt or MDBList list — without walking the full
/// collections editor.
///
/// Collections are persisted as raw dictionaries so Android-only keys survive
/// a tvOS round-trip, so a quick add writes exactly the shape the editor
/// writes and hands it to `CollectionsStore.saveLocalEdit`, which posts the
/// locally-edited notification the sync manager already pushes. No new sync
/// path, and nothing here has to be registered with Home: a new collection is
/// enabled on Home by default.
enum CollectionQuickAdd {
    /// Title of an existing collection that already draws this person's
    /// credits, or nil. Used to keep the person page's button truthful and to
    /// refuse a duplicate shelf.
    static func personCollectionTitle(tmdbId: Int) -> String? {
        for collection in CollectionsStore.rawCollections() {
            let folders = (collection["folders"] as? [[String: Any]]) ?? []
            for folder in folders {
                let sources = (folder["sources"] as? [[String: Any]]) ?? []
                for source in sources where isPersonSource(source, tmdbId: tmdbId) {
                    return (collection["title"] as? String) ?? ""
                }
            }
        }
        return nil
    }

    /// Adds a TMDB person as a one-row Home shelf. Directors are written as
    /// `DIRECTOR` so the resolver keeps only their directing credits, matching
    /// what the collections editor's TMDB source type means.
    ///
    /// Returns false when the person is already on Home. The caller should
    /// only report success on true.
    @discardableResult
    static func addPerson(name: String, tmdbId: Int, role: String?) -> Bool {
        guard personCollectionTitle(tmdbId: tmdbId) == nil else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? "TMDB Person" : trimmedName
        let isDirector = (role ?? "").lowercased().contains("director")
        let source: [String: Any] = [
            "provider": "tmdb",
            "tmdbSourceType": isDirector ? "DIRECTOR" : "PERSON",
            "tmdbId": tmdbId,
            "title": title,
            "mediaType": "movie"
        ]
        append(makeCollection(title: title, source: source))
        return true
    }

    /// Wraps a source dictionary produced by the editor's Trakt / MDBList
    /// sheets into a new pinned, rows-style collection — the same shape the
    /// editor would build by hand.
    @discardableResult
    static func addList(source: [String: Any], fallbackTitle: String) -> Bool {
        let storedTitle = (source["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = storedTitle.isEmpty
            ? fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            : storedTitle
        append(makeCollection(title: title.isEmpty ? "My List" : title, source: source))
        return true
    }

    private static func isPersonSource(_ source: [String: Any], tmdbId: Int) -> Bool {
        guard (source["provider"] as? String)?.lowercased() == "tmdb" else { return false }
        let type = (source["tmdbSourceType"] as? String)?.uppercased()
        guard type == "PERSON" || type == "DIRECTOR" else { return false }
        return (source["tmdbId"] as? Int) == tmdbId || (source["tmdbId"] as? NSNumber)?.intValue == tmdbId
    }

    private static func makeCollection(title: String, source: [String: Any]) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "title": title,
            // A quick add is a single shelf the user asked for, so it pins and
            // browses as rows rather than opening a folder of one tab.
            "pinToTop": true,
            "viewMode": "ROWS",
            "showAllTab": false,
            "folders": [
                [
                    "id": UUID().uuidString,
                    "title": title,
                    "tileShape": "POSTER",
                    "focusGifEnabled": true,
                    "hideTitle": false,
                    "sources": [source]
                ] as [String: Any]
            ]
        ]
    }

    private static func append(_ collection: [String: Any]) {
        var all = CollectionsStore.rawCollections()
        all.append(collection)
        CollectionsStore.saveLocalEdit(all)
    }
}
