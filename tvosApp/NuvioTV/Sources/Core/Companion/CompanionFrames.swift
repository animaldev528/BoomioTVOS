//
//  CompanionFrames.swift
//  NuvioTV
//
//  Boomio: the wire frames of the bsc companion hub.
//
//  The contract lives in `bsc/services/device-relay.js` and is shared verbatim
//  with the Android TV client; the field names here are that contract, not an
//  invention. Outbound frames are encoded with `JSONEncoder`; every inbound
//  field is optional because the hub sends only the ones a command needs.
//

import Foundation

enum CompanionOutbound {
    /// First frame on every socket. `deviceId` is the install identity the
    /// session was minted for, so the hub can key presence and pairing on it.
    struct Register: Encodable {
        let type = "register"
        let deviceId: String
        let name: String
        let platform: String
        let ip: String?
        /// Optional in the hub (`handleRegister` resolves identity best-effort),
        /// but sending it lets the server attach a user to this TV row.
        let sessionToken: String?

        enum CodingKeys: String, CodingKey {
            case type, deviceId, name, platform, ip
            case sessionToken = "session_token"
        }
    }

    /// ~1 s telemetry while a player is alive.
    struct PlaybackPosition: Encodable {
        let type = "playback_position"
        let positionMs: Int64
        let durationMs: Int64
        let isPlaying: Bool
        let streamUrl: String?
        let imdbId: String?
        let title: String?
        let season: Int?
        let episode: Int?
        let posterUrl: String?
        let contentType: String?
        let volumePercent: Int
    }

    /// Sent once when playback ends so the hub clears `device:position:<id>`
    /// instead of waiting for its 60 s TTL.
    struct PlaybackStopped: Encodable {
        let type = "playback_stopped"
    }

    /// Answer to a phone's `audio_fork_start` / `audio_fork_stop`. The hub
    /// forwards any `audio_fork`-typed frame from a TV to its paired phone,
    /// and the phone's private-listening UI stays in "starting" until it hears
    /// one. tvOS has no way to tap its decoded audio into the phone's UDP
    /// format, so this client answers `error` instead of going silent — the
    /// viewer gets "unavailable" rather than a toggle that hangs.
    struct AudioForkStatus: Encodable {
        let type = "audio_fork"
        let status: String
        let reason: String?
    }
}

/// A frame from the hub (a paired phone, a watch party, or legacy bsm).
///
/// Unknown keys — including `_from` and `_phoneDeviceId` — are ignored by
/// `JSONDecoder`; the fields the TV acts on are all that is declared.
struct CompanionInbound: Decodable {
    let type: String
    let partyId: String?
    let positionMs: Int64?
    let isPlaying: Bool?
    let percent: Int?
    let keyCode: Int?
    let text: String?
    let reason: String?
    let status: String?
    /// `play`: the stream the phone already resolved, and what it is.
    let url: String?
    let title: String?
    let imdbId: String?
    let season: Int?
    let episode: Int?
    /// Milliseconds; the player's seam takes seconds.
    let resumeFrom: Double?

    /// The cast, when the frame is a usable one. `url` is the only field the
    /// TV cannot invent, so a `play` without it is dropped rather than played
    /// as an empty stream.
    var playRequest: CompanionPlayRequest? {
        guard type == "play",
              let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let target = URL(string: raw),
              target.scheme != nil
        else { return nil }

        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CompanionPlayRequest(
            url: target,
            title: name?.nilWhenEmpty ?? "Boomio",
            imdbId: imdbId?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty,
            season: season,
            episode: episode,
            resumeFromMs: resumeFrom
        )
    }
}

/// A phone's `play` command, carried to the root view through `CompanionRemote`
/// once the frame has been validated.
struct CompanionPlayRequest: Equatable, Sendable {
    let url: URL
    let title: String
    let imdbId: String?
    let season: Int?
    let episode: Int?
    let resumeFromMs: Double?

    var isSeries: Bool { season != nil }

    /// The phone resolves the stream itself and hands over an already-playable
    /// URL, so nothing here goes back to an add-on for a source. What the TV
    /// still needs is an identity — for the player overlay, the episode line
    /// and progress scrobbling — and the frame carries exactly that much.
    func meta(type: String) -> NuvioMeta {
        NuvioMeta(
            id: imdbId ?? url.absoluteString,
            name: title,
            imdbId: imdbId,
            type: type
        )
    }

    /// The episode the phone cast, in the identity the player and the progress
    /// stores expect (`<series id>:<season>:<episode>`). The episode's own name
    /// is not on the wire, so the show's title stands in for it.
    func episodeVideo(for meta: NuvioMeta) -> NuvioVideo? {
        guard let season, let episode else { return nil }
        return NuvioVideo(
            id: "\(meta.streamId):\(season):\(episode)",
            title: title,
            season: season,
            episode: episode
        )
    }

    /// "S1 · E2" — the line the player shows under the title, and the one
    /// `PlayerView.subtitleContentId` parses back into the episode identity.
    var subtitle: String {
        guard let season, let episode else { return "" }
        return "S\(season) · E\(episode)"
    }

    var resumeFromSeconds: Double? {
        guard let resumeFromMs, resumeFromMs > 0 else { return nil }
        return resumeFromMs / 1000
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
