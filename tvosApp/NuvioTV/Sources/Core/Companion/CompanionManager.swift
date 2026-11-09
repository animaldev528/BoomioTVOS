//
//  CompanionManager.swift
//  NuvioTV
//
//  Boomio: the TV end of the bsc companion hub.
//
//  The TV opens an outbound WebSocket to `{serviceOrigin}/bsc/ws`, registers
//  itself, streams ~1 s playback telemetry, and applies the phone's remote
//  commands to whichever player is in front. This is the same socket the
//  Android TV client opens (`BoomioCompanionManager`), against the contract in
//  `bsc/services/device-relay.js`; it is what puts the TV in the phone's
//  companion device list and lets the phone drive it.
//
//  Three facts from the Android implementation are load-bearing here:
//
//   1. The hub URL comes from the CURRENT server configuration, never from a
//      value captured at launch. Discovery/onboarding can rewrite the box while
//      a healthy socket is up, and a healthy socket never drops on its own —
//      hence the 15 s origin watch. (Android measured a TV stuck on the first
//      box's relay for the life of the process.)
//   2. Registration is allowed without a session token, but sending the one the
//      device paired with lets the hub resolve the owner of the TV row.
//   3. Commands are best-effort: a command for a player that is not on screen
//      is dropped, not queued.
//

import Foundation
import UIKit
import os

@MainActor
final class CompanionManager: NSObject {
    static let shared = CompanionManager()

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case waiting(seconds: Int)
    }

    private(set) var state: State = .idle

    private var urlSession: URLSession!
    private var socket: URLSessionWebSocketTask?
    /// The URL the CURRENT socket was opened against. A socket keeps the host it
    /// dialled, so this is what tells "already on the right box" from "the app
    /// has moved".
    private var connectedURL: URL?
    private var stopped = true
    private var backoffAttempt = 0

    private var originWatch: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// Whether the last telemetry sample had a player. Lets the manager send one
    /// `playback_stopped` on the playing -> idle edge instead of every second.
    private var lastTelemetryHadPlayer = false
    /// A phone scrub pauses playback and resumes it on commit. State lives here
    /// because the hub sends no "was playing" flag in `scrub_commit`.
    private var scrubbingWasPlaying = false

    private let log = Logger(subsystem: "com.nuvio.tv.boomio", category: "Companion")

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        // The delegate carries both the WebSocket callbacks and the client
        // certificate challenge, so the socket presents the enrolled leaf the
        // same way every REST session does.
        urlSession = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }

    // MARK: - Lifecycle

    /// Brings the socket in line with the current box. Safe to call repeatedly;
    /// also safe before onboarding has configured a server — the origin watch
    /// picks the box up once `ServerConfigurationStore` gets one.
    func start() {
        stopped = false
        ensureOriginWatch()
        ensureConnection()
    }

    func stop() {
        stopped = true
        cancelConnectionTasks()
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connectedURL = nil
        state = .idle
    }

    // MARK: - URL

    private func currentWebSocketURL() -> URL? {
        guard AuthConfig.isConfigured,
              let backend = URL(string: AuthConfig.normalizedAPIBaseURL),
              let plane = BoomioPlane(backendURL: backend)
        else { return nil }

        var components = URLComponents(url: plane.serviceOrigin, resolvingAgainstBaseURL: false)
        components?.scheme = plane.serviceOrigin.scheme?.lowercased() == "http" ? "ws" : "wss"
        components?.path = "/bsc/ws"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private func sessionToken(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return BoomioSecureStore.string("overlay.session." + host)
    }

    // MARK: - Connection

    private func ensureConnection() {
        guard !stopped else { return }

        guard let target = currentWebSocketURL() else {
            cancelConnectionTasks()
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            connectedURL = nil
            state = .idle
            return
        }

        // Exactly one socket for the life of the process. A launch can call
        // `start()` several times before the first socket reaches `.running`
        // (the task begins suspended, and SwiftUI may build the app struct
        // more than once), and "state is not running yet" is not a reason to
        // dial a second one — that is how an Apple TV ended up holding fifteen
        // parallel sockets on one hub. A moved box is `reconcileOrigin`'s job.
        if socket != nil { return }
        if reconnectTask != nil { return }
        connect(to: target)
    }

    private func connect(to target: URL) {
        cancelConnectionTasks()
        // A socket keeps the host it dialled. When the origin moved, the old
        // connection belongs to a box this app no longer serves; cancel it
        // rather than closing so it does not linger without a receive loop.
        socket?.cancel(with: .goingAway, reason: nil)
        log.info("opening companion socket to \(target.absoluteString, privacy: .public)")

        connectedURL = target
        state = .connecting

        let task = urlSession.webSocketTask(with: target)
        socket = task
        task.resume()

        receiveLoop(on: task)
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self, !Task.isCancelled, self.socket === task else { return }
                    switch message {
                    case .string(let text):
                        self.handleInbound(text)
                    case .data(let data):
                        self.handleInbound(String(decoding: data, as: UTF8.self))
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.handleDisconnect(task, reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func sendRegister() {
        let name = UIDevice.current.name.isEmpty ? "Apple TV" : UIDevice.current.name
        let frame = CompanionOutbound.Register(
            deviceId: BoomioClientIdentity.shared.deviceId,
            name: name,
            platform: "appletv",
            ip: nil,
            sessionToken: connectedURL.flatMap(sessionToken(for:))
        )
        log.info("registering \(BoomioClientIdentity.shared.deviceId, privacy: .public)")
        send(frame)
    }

    private func send<T: Encodable>(_ frame: T) {
        guard let task = socket, task.state == .running else { return }
        do {
            let data = try JSONEncoder().encode(frame)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                do {
                    try await task.send(.string(text))
                } catch {
                    self?.log.debug("companion send failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            log.error("companion encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Telemetry

    private func telemetryLoop() {
        telemetryTask?.cancel()
        telemetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sendTelemetrySample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func sendTelemetrySample() {
        guard let task = socket, task.state == .running else { return }

        guard let player = CompanionPlayerRegistry.shared.current else {
            if lastTelemetryHadPlayer {
                lastTelemetryHadPlayer = false
                send(CompanionOutbound.PlaybackStopped())
            }
            return
        }

        lastTelemetryHadPlayer = true
        let snapshot = player.companionSnapshot
        send(CompanionOutbound.PlaybackPosition(
            positionMs: snapshot.positionMs,
            durationMs: snapshot.durationMs,
            isPlaying: snapshot.isPlaying,
            streamUrl: snapshot.streamUrl,
            imdbId: snapshot.imdbId,
            title: snapshot.title,
            season: snapshot.season,
            episode: snapshot.episode,
            posterUrl: snapshot.posterUrl,
            contentType: snapshot.contentType,
            volumePercent: snapshot.volumePercent
        ))
    }

    // MARK: - Origin watch

    /// There is no callback for "the user pointed the app at another box": the
    /// server configuration is a stored value, and a healthy socket emits no
    /// event that would reveal the difference. A 15 s tick is the smallest
    /// honest check — longer than a discovery round trip, far shorter than a
    /// viewing session.
    private func ensureOriginWatch() {
        guard originWatch == nil else { return }
        originWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled, !self.stopped else { return }
                self.reconcileOrigin()
            }
        }
    }

    private func reconcileOrigin() {
        let target = currentWebSocketURL()
        if connectedURL == target {
            // Still connected, or still unconfigured: nothing to do. A dropped
            // socket leaves connectedURL nil, and `target` non-nil reconnects
            // here even if the failure path never rescheduled.
            if target != nil, socket == nil, reconnectTask == nil {
                ensureConnection()
            }
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        backoffAttempt = 0

        guard let target else {
            cancelConnectionTasks()
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            connectedURL = nil
            state = .idle
            return
        }
        connect(to: target)
    }

    // MARK: - Inbound

    private func handleInbound(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let frame: CompanionInbound
        do {
            frame = try JSONDecoder().decode(CompanionInbound.self, from: data)
        } catch {
            log.debug("undecodable companion frame: \(String(text.prefix(160)), privacy: .public)")
            return
        }

        let player = CompanionPlayerRegistry.shared.current

        switch frame.type {
        case "registered":
            backoffAttempt = 0
            state = .connected
            log.info("companion hub registered this TV")
            sendTelemetrySample()

        case "stealth_playpause":
            player?.companionTogglePlayPause()

        case "party_set_playing":
            // The hub broadcasts the desired state, not a toggle, so a
            // "resume" always resumes even if the TV was already playing.
            player?.companionSetPlaying(frame.isPlaying ?? false)

        case "party_seek":
            if let ms = frame.positionMs {
                player?.companionSeek(toMilliseconds: ms)
            }

        case "scrub_start":
            guard let player else { return }
            scrubbingWasPlaying = player.companionSnapshot.isPlaying
            player.companionSetPlaying(false)

        case "scrub_commit":
            guard let player else { return }
            if let ms = frame.positionMs {
                player.companionSeek(toMilliseconds: ms)
            }
            if scrubbingWasPlaying {
                player.companionSetPlaying(true)
            }
            scrubbingWasPlaying = false

        case "stop":
            player?.companionStop()

        case "companion_paired":
            log.info("companion phone connected")

        case "companion_unpaired":
            log.info("companion phone disconnected")

        case "stealth_volume":
            // tvOS exposes no system volume to apps and the player has no
            // per-player volume seam. Logged once per command so the phone's
            // volume rocker is visibly a no-op rather than silently ignored.
            log.info("stealth_volume ignored: tvOS has no app-controllable volume")

        case "stealth_keyevent", "inject_keyevent":
            // The hub turns the phone's transport keys into their own commands
            // (play/pause, scrub) before they reach a TV, so what is left here
            // is the D-pad — applied by the surface in front rather than
            // injected into the focus engine, which tvOS does not expose.
            handleKeyEvent(frame.keyCode, player: player)

        case "stealth_search":
            // The phone's search box is the keyboard and the mic the TV lacks.
            // Opening it here means pressing Enter on the phone is all the
            // viewer does; the query itself arrives in `keyboard_input`.
            CompanionRemote.post(.companionSearchRequested)

        case "keyboard_input":
            if let text = frame.text {
                CompanionRemote.post(.companionSearchText, text: text)
            }

        case "keyboard_submit":
            CompanionRemote.post(.companionSearchSubmitted)

        case "audio_fork_start":
            // Private listening. The phone binds a UDP socket and waits for
            // this client's `started` ack; tvOS has no seam to tap the player's
            // decoded audio into that format, so answer `error` — the phone maps
            // an unknown reason to "unavailable" and leaves the toggle off,
            // instead of hanging in "starting" until its timeout.
            log.info("audio fork refused: tvOS cannot tap the decoded audio")
            send(CompanionOutbound.AudioForkStatus(status: "error", reason: "unsupported_platform"))

        case "audio_fork_stop":
            // Nothing was ever armed; still answer so the phone's state machine
            // settles instead of waiting on a stop ack.
            send(CompanionOutbound.AudioForkStatus(status: "stopped", reason: nil))

        case "play", "iptv_tune", "music_identify":
            log.info("\(frame.type, privacy: .public) is not implemented on tvOS yet")

        default:
            log.debug("unhandled companion command: \(frame.type, privacy: .public)")
        }
    }

    // MARK: - D-pad

    /// The key codes the phone remote sends (`CompanionKeyCodes` in
    /// NuvioMobile), in Android's numbering.
    private enum RemoteKey {
        static let back = 4
        static let dpadUp = 19
        static let dpadDown = 20
        static let dpadLeft = 21
        static let dpadRight = 22
        static let dpadCenter = 23
        static let playPause = 85
        /// Matches what bsc's phone relay uses for its own scrub commits, so a
        /// D-pad seek and a phone scrub translate to the same jump on screen.
        static let seekStepMs: Int64 = 15_000
    }

    private func handleKeyEvent(_ keyCode: Int?, player: (any CompanionPlayerControlling)?) {
        guard let keyCode else { return }

        switch keyCode {
        case RemoteKey.back:
            // Always posted: the player scene unwinds its own panels and then
            // leaves, exactly as the Siri remote's Menu does; the root view
            // acts only when no player is mounted.
            CompanionRemote.post(.companionBackPressed)

        case RemoteKey.dpadLeft, RemoteKey.dpadRight:
            guard let player else {
                log.debug("D-pad seek with no player on screen: ignored")
                return
            }
            let snapshot = player.companionSnapshot
            let delta = keyCode == RemoteKey.dpadLeft ? -RemoteKey.seekStepMs : RemoteKey.seekStepMs
            var target = snapshot.positionMs + delta
            if target < 0 { target = 0 }
            if snapshot.durationMs > 0, target > snapshot.durationMs { target = snapshot.durationMs }
            player.companionSeek(toMilliseconds: target)

        case RemoteKey.dpadCenter, RemoteKey.playPause:
            guard let player else {
                log.debug("D-pad play/pause with no player on screen: ignored")
                return
            }
            player.companionTogglePlayPause()

        case RemoteKey.dpadUp, RemoteKey.dpadDown:
            // Vertical D-pad would mean moving focus between controls. Apps
            // cannot drive tvOS's focus engine from a socket, and the player
            // has no vertical transport, so this is a visible no-op rather
            // than a guess that moves playback by accident.
            log.debug("D-pad up/down ignored: tvOS focus is not app-drivable")

        default:
            log.debug("unmapped remote key \(keyCode) from companion")
        }
    }

    // MARK: - Reconnect

    private func handleDisconnect(_ task: URLSessionWebSocketTask, reason: String?) {
        guard socket === task else { return }
        log.info("companion socket closed: \(reason ?? "no reason", privacy: .public)")
        socket = nil
        connectedURL = nil
        state = .idle
        cancelConnectionTasks()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, reconnectTask == nil else { return }
        backoffAttempt = min(backoffAttempt + 1, 5)
        let seconds = min(pow(2.0, Double(backoffAttempt - 1)), 30.0)
        state = .waiting(seconds: Int(seconds))
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.reconnectTask = nil
            self.ensureConnection()
        }
    }

    private func cancelConnectionTasks() {
        receiveTask?.cancel()
        receiveTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        lastTelemetryHadPlayer = false
    }
}

// MARK: - URLSession delegates

extension CompanionManager: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === webSocketTask else { return }
            self.sendRegister()
            self.telemetryLoop()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor [weak self] in
            self?.handleDisconnect(webSocketTask, reason: text)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil, let webSocketTask = task as? URLSessionWebSocketTask else { return }
        Task { @MainActor [weak self] in
            self?.handleDisconnect(webSocketTask, reason: error?.localizedDescription)
        }
    }
}

extension CompanionManager: URLSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Same rule as the REST session: the identity answers only for the
        // enrolled host, and only once the edge has accepted this leaf.
        if let credential = BoomioClientIdentity.shared.clientCredential(for: challenge.protectionSpace) {
            completionHandler(.useCredential, credential)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
