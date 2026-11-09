import Foundation
import SwiftUI

/// Actions the tile long-press menu offers that need the app root: a screen to
/// push ("More like this") or a sheet to present ("Add a public list to
/// Home"). A shared bus rather than a callback because the menu rides on
/// `PosterCard`, which every screen in the app mounts — threading two more
/// closures through each of those call sites would be churn with no payoff.
final class TitleActionBus: ObservableObject {
    static let shared = TitleActionBus()

    /// Set to a title to push the "More like this" screen for it.
    @Published var moreLikeThis: NuvioMeta?
    /// Set to a title to push the "Public Lists" screen for it.
    @Published var publicLists: NuvioMeta?
    /// True while the "Add a public list to Home" picker should be showing.
    @Published var isAddingPublicList = false

    func openMoreLikeThis(for meta: NuvioMeta) {
        moreLikeThis = meta
    }

    func openPublicLists(for meta: NuvioMeta) {
        publicLists = meta
    }

    func openPublicListPicker() {
        isAddingPublicList = true
    }
}

/// Like / Not interested, recorded on the device.
///
/// The taste engine that turns feedback into rows runs server-side and has no
/// feedback endpoint yet, so the menu records the signal locally: "Not
/// interested" hides the title from the rows the app draws, "Like" marks it.
/// Both are keyed by the title's own id and type, so they hold across add-ons
/// and relaunches.
///
/// A dismissal expires: tiles that were hidden are the one thing in the app
/// that cannot be long-pressed again, so instead of an undo screen the signal
/// ages out and the title comes back on its own.
enum TitleFeedbackStore {
    /// Rows re-read their items when this fires.
    static let changedNotification = Notification.Name("tvos.titleFeedback.changed")

    /// How long a "Not interested" hides its title.
    private static let dismissalLifetime: TimeInterval = 30 * 24 * 60 * 60

    private static let likedKey = "tvos.titleFeedback.liked"
    private static let dismissedKey = "tvos.titleFeedback.dismissed"

    static func key(for meta: NuvioMeta) -> String {
        "\(meta.type.lowercased())|\(meta.id)"
    }

    static func isLiked(_ meta: NuvioMeta) -> Bool {
        liked().contains(key(for: meta))
    }

    static func isDismissed(_ meta: NuvioMeta) -> Bool {
        guard let dismissedAt = dismissed()[key(for: meta)] else { return false }
        return Date().timeIntervalSince1970 - dismissedAt < dismissalLifetime
    }

    static func setLiked(_ liked: Bool, for meta: NuvioMeta) {
        var set = self.liked()
        if liked {
            set.insert(key(for: meta))
        } else {
            set.remove(key(for: meta))
        }
        UserDefaults.standard.set(Array(set), forKey: likedKey)
    }

    static func setDismissed(_ isDismissed: Bool, for meta: NuvioMeta) {
        var map = dismissed()
        if isDismissed {
            map[key(for: meta)] = Date().timeIntervalSince1970
        } else {
            map.removeValue(forKey: key(for: meta))
        }
        UserDefaults.standard.set(map, forKey: dismissedKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Dismissals that are still in force, dropping the expired ones.
    private static func liveDismissals() -> [String: TimeInterval] {
        let cutoff = Date().timeIntervalSince1970 - dismissalLifetime
        return dismissed().filter { $0.value >= cutoff }
    }

    static func dismissedCount() -> Int {
        liveDismissals().count
    }

    static func clearDismissed() {
        UserDefaults.standard.removeObject(forKey: dismissedKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// The items a row should draw: everything except what the viewer asked
    /// not to see.
    static func visible(_ items: [NuvioMeta]) -> [NuvioMeta] {
        let hidden = liveDismissals()
        guard !hidden.isEmpty else { return items }
        return items.filter { hidden[key(for: $0)] == nil }
    }

    private static func liked() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: likedKey) ?? [])
    }

    private static func dismissed() -> [String: TimeInterval] {
        let raw = UserDefaults.standard.dictionary(forKey: dismissedKey) ?? [:]
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
}
