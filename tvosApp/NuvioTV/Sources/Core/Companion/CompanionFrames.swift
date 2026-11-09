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
}
