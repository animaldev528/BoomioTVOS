import Foundation
import Combine

/// Owns one hub destination's data (Movies, TV or Anime).
///
/// Sections are published as they finish, in the hub's own order, so the first
/// rows are usable while later drilldowns are still loading — a hub that shows
/// nothing until every catalog has answered reads as broken on a slow add-on
/// host.
@MainActor
final class HubBrowseViewModel: ObservableObject {
    let kind: TVHubKind

    @Published private(set) var sections: [TVHubSection] = []
    @Published private(set) var isLoading = false
    /// True only once a full load finished without a single section: an empty
    /// hub mid-load is still an empty screen, but not an empty answer.
    @Published private(set) var isEmpty = false

    private let repository: CinemetaCatalogRepository
    private var loadTask: Task<Void, Never>?
    private var generation: UInt = 0
    /// A load cut short by leaving the tab left the rows incomplete; the next
    /// activation has to finish them rather than trust what is on screen.
    private var loadCompleted = false

    init(kind: TVHubKind, repository: CinemetaCatalogRepository = CinemetaCatalogRepository()) {
        self.kind = kind
        self.repository = repository
    }

    /// Loads only when there is nothing to show or a previous load was cut
    /// short, so re-entering the tab does not re-fetch every row.
    func loadIfNeeded(force: Bool = false) {
        if !force, loadCompleted { return }
        load(force: force)
    }

    func load(force: Bool = false) {
        guard loadTask == nil else { return }
        if !force, loadCompleted { return }
        generation &+= 1
        let expected = generation
        sections = []
        isEmpty = false
        isLoading = true
        loadCompleted = false
        loadTask = Task { [weak self] in
            guard let self else { return }
            let plan = await self.repository.hubCatalogSources(kind: self.kind)
            guard self.generation == expected, !Task.isCancelled else { return }
            var loaded: [TVHubSection] = []
            // The provider ribbons are the hub's top band, so they load — and
            // publish — before any regular section: the first screenful should
            // be the spotlight, not a list that fills in underneath it.
            for group in plan.spotlights {
                guard self.generation == expected, !Task.isCancelled else { return }
                let rows = await self.repository.hubSpotlightRows(for: group)
                guard self.generation == expected, !Task.isCancelled else { return }
                guard !rows.isEmpty else { continue }
                loaded.append(TVHubSection(
                    id: group.id,
                    title: group.title,
                    addonName: group.sources.first?.addonName ?? "",
                    rows: rows
                ))
                self.sections = loaded
            }
            for source in plan.sections {
                guard self.generation == expected, !Task.isCancelled else { return }
                if let section = await self.repository.hubSection(for: source) {
                    loaded.append(section)
                    self.sections = loaded
                }
            }
            guard self.generation == expected else { return }
            self.isLoading = false
            self.isEmpty = loaded.isEmpty
            self.loadCompleted = true
            self.loadTask = nil
        }
    }

    /// Drops the visible rows and abandons the in-flight load. The next
    /// activation reloads.
    func cancel() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        loadCompleted = false
    }
}
