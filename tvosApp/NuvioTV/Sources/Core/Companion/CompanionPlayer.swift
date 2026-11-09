//
//  CompanionPlayer.swift
//  NuvioTV
//
//  Boomio: the player surface the companion hub drives, and the registry that
//  tells the hub which player is in front.
//
//  The Android TV client exposes this as `CompanionPlaybackBridge`; tvOS has no
//  Hilt graph, so the equivalent is a weak registry filled by `PlayerView` while
//  its view model is alive. A weak reference is deliberate: the manager polls
//  telemetry once a second for the life of the process, and a strong hold on a
//  dismissed `PlayerViewModel` would keep a whole playback session (and its
//  engine) alive after the viewer left it.
//

import Foundation

/// What the bsc companion hub needs to name and position what the TV is playing.
///
/// Field-for-field the payload `handlePosition` in `bsc/services/device-relay.js`
/// writes to `device:position:<deviceId>`. The phone's "now playing" card reads
/// that record, so a field missing here is a field the remote cannot display.
struct CompanionPlaybackSnapshot {
    var positionMs: Int64
    var durationMs: Int64
    var isPlaying: Bool
    var streamUrl: String?
    var imdbId: String?
    var title: String?
    var season: Int?
    var episode: Int?
    var posterUrl: String?
    /// `"movie"`, `"series"` or `"channel"` — the phone uses this to tell a
    /// live channel from a VOD title that also puts an id in `imdbId`.
    var contentType: String?
    /// tvOS apps cannot read or set system volume, so this stays 0. Kept in the
    /// snapshot so the wire shape matches the Android client's.
    var volumePercent: Int = 0
}

/// The transport surface a companion remote command can reach.
///
/// One player at a time registers; commands delivered while nothing is playing
/// are dropped rather than queued, exactly as the Android bridge behaves.
@MainActor
protocol CompanionPlayerControlling: AnyObject {
    var companionSnapshot: CompanionPlaybackSnapshot { get }
    func companionTogglePlayPause()
    func companionSetPlaying(_ playing: Bool)
    func companionSeek(toMilliseconds milliseconds: Int64)
    func companionStop()
}

/// The player currently on screen, if any.
@MainActor
final class CompanionPlayerRegistry {
    static let shared = CompanionPlayerRegistry()

    private weak var active: (any CompanionPlayerControlling)?

    private init() {}

    var current: (any CompanionPlayerControlling)? { active }

    func activate(_ player: any CompanionPlayerControlling) {
        active = player
    }

    /// Only the player that registered may unregister: a retiring view must not
    /// clear a newer one that replaced it during a transition.
    func deactivate(_ player: any CompanionPlayerControlling) {
        guard let active, active === player else { return }
        self.active = nil
    }
}
