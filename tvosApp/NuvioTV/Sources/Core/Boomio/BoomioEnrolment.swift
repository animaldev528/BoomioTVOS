//
//  BoomioEnrolment.swift
//  NuvioTV
//
//  Boomio: pair this TV with the box, register its certificate, enrol its
//  tunnel key.
//
//  The sequence is forced by the server:
//
//    1. device/request  -> a user code the human approves at verification_uri
//    2. device/poll     -> `bs_ses_…`, whose session device_id is ours
//    3. overlay/cert    -> the certificate, whose CN is derived from that id
//    4. overlay/enroll  -> our WireGuard public key
//
//  Step 3 is the one that matters: the edge keys the media plane on the
//  presented leaf, so a registered certificate is what makes /bsf work. Steps
//  1–2 are also how the TV obtains a companion session at all — the Supabase
//  token the rest of the app uses is not one.
//
//  The session is kept in the Keychain, per box, because it outlives the
//  launch: the server issues it for 90 days, and holding it is what lets a
//  later launch re-register the SAME certificate after a box-side reset
//  without asking a human to approve a new code. A 401/403 on that path means
//  the session is gone or the device was revoked, and only then does the flow
//  fall back to pairing.
//
//  ⚠️ tvOS has no Network Extension entitlement, so the tunnel is never
//  dialled. Enrolment is still performed: the box needs the public key to know
//  the device, and the panel is honest about the tunnel being inert rather than
//  pretending the feature does not exist.
//

import Combine
import CryptoKit
import Foundation

@MainActor
final class BoomioEnrolment: ObservableObject {
    enum Stage: Equatable {
        case idle
        case pairing(userCode: String, verificationURI: URL)
        case registering
        case enrolling
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .pairing, .registering, .enrolling: return true
            default: return false
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var certificateFingerprint: String?
    @Published private(set) var tunnelAddress: String?
    @Published private(set) var serverPublicKey: String?
    @Published private(set) var endpoint: String?
    /// Public half of this device's tunnel key. Safe to display; the private
    /// half never leaves the Keychain.
    @Published private(set) var devicePublicKey: String?

    private var task: Task<Void, Never>?
    private var plane: BoomioPlane?
    private var sessionToken: String?
    private var sessionAccount: String?
    private var serverName: String = ""
    /// Identifies the current run. A cancelled run can still be mid-request;
    /// it must not write its result over a newer one.
    private var runId = 0

    deinit { task?.cancel() }

    var isReady: Bool { if case .ready = stage { return true }; return false }

    /// Runs the whole sequence. Safe to call again after a failure; a second
    /// call while one is in flight replaces it rather than stacking codes.
    func start(plane: BoomioPlane, serverName: String) {
        task?.cancel()
        runId += 1
        let run = runId

        self.plane = plane
        self.serverName = serverName
        sessionAccount = Self.sessionAccount(for: plane)
        if let account = sessionAccount {
            sessionToken = BoomioSecureStore.string(account)
        }
        stage = .idle

        task = Task { [weak self] in
            await self?.run(plane: plane, serverName: serverName, run: run)
            if let self, self.runId == run { self.task = nil }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runId += 1
        // A failure is the operator's to read; cancelling must not erase it.
        if case .failed = stage { return }
        stage = .idle
    }

    /// Re-arms certificate presentation on a launch that never opens
    /// onboarding.
    ///
    /// Presentation lives in memory (see `BoomioClientIdentity`), because the
    /// edge is the only authority on whether it still lists this leaf. So a
    /// fresh process starts certless by design, and this is what leaves that
    /// state: the stored session re-registers the SAME certificate without a
    /// human, and a success re-arms presentation for the rest of the launch.
    /// Nothing is shown to the user — onboarding is where a failure belongs.
    func resumeRegistration(plane: BoomioPlane) {
        sessionAccount = Self.sessionAccount(for: plane)
        guard let account = sessionAccount,
              let token = BoomioSecureStore.string(account)
        else { return }

        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = BoomioClientIdentity.shared
                let certificate = try identity.certificate()
                let reply = try await BoomioAPI(plane: plane).registerCertificate(
                    pem: certificate.pem,
                    fingerprint: identity.hardwareFingerprint,
                    sessionToken: token
                )
                if let host = plane.expectedServiceHost {
                    identity.markRegistered(host: host)
                }
                if self.runId == 0 { self.certificateFingerprint = reply.fingerprint_sha256 }
            } catch {
                // Stay certless. The media and sign-in surface admits that, and
                // onboarding will pair afresh if the session is truly gone.
            }
            if self.runId == 0 { self.task = nil }
        }
    }

    /// Re-registers the existing certificate with the session already held.
    /// This is the recovery path when the edge reports the device as unknown —
    /// it re-sends the SAME bytes, which is what the allow-list needs.
    func reregisterCertificate() async {
        guard let plane = plane, let token = sessionToken else { return }
        do {
            let certificate = try BoomioClientIdentity.shared.certificate()
            stage = .registering
            let reply = try await BoomioAPI(plane: plane).registerCertificate(
                pem: certificate.pem,
                fingerprint: BoomioClientIdentity.shared.hardwareFingerprint,
                sessionToken: token
            )
            certificateFingerprint = reply.fingerprint_sha256
            if let host = plane.expectedServiceHost {
                BoomioClientIdentity.shared.markRegistered(host: host)
            }
            stage = .ready
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Sequence

    private func run(plane: BoomioPlane, serverName: String, run: Int) async {
        let api = BoomioAPI(plane: plane)
        let identity = BoomioClientIdentity.shared

        do {
            // Mint (or reuse) the certificate first: if the Keychain refuses
            // there is no point asking a human to approve a code.
            let certificate = try identity.certificate()
            guard isCurrent(run) else { return }
            certificateFingerprint = certificate.fingerprintSHA256

            // A stored session skips the human entirely. Only an expiry or a
            // revocation sends the flow back to pairing.
            if let token = sessionToken {
                do {
                    try await registerAndEnrol(plane: plane, certificate: certificate, token: token, run: run)
                    return
                } catch let error as AuthError where error.statusCode == 401 || error.statusCode == 403 {
                    clearSession()
                    guard isCurrent(run) else { return }
                }
            }

            try Task.checkCancellation()

            let challenge = try await api.requestPairing(request: BoomioAPI.PairRequest(
                device_id: identity.deviceId,
                platform: "tvos",
                type: "tv",
                name: serverName.isEmpty ? "Apple TV" : serverName,
                hw_fingerprint: identity.hardwareFingerprint,
                capabilities: ["can_play": true]
            ))
            guard isCurrent(run) else { return }
            guard let verificationURI = URL(string: challenge.verification_uri) else {
                throw AuthError(message: "the box returned an unusable approval address", statusCode: nil)
            }
            stage = .pairing(userCode: challenge.user_code, verificationURI: verificationURI)

            let token = try await waitForApproval(api: api, challenge: challenge)
            guard let sessionToken = token else {
                // Cancelled: without this the screen stays on the code
                // forever, because nothing after the guard ever runs.
                if isCurrent(run) { stage = .idle }
                return
            }
            guard isCurrent(run) else { return }
            self.sessionToken = sessionToken
            if let account = sessionAccount {
                BoomioSecureStore.save(sessionToken, account: account)
            }

            try await registerAndEnrol(plane: plane, certificate: certificate, token: sessionToken, run: run)
        } catch is CancellationError {
            if isCurrent(run) { stage = .idle }
        } catch {
            if isCurrent(run) { stage = .failed(error.localizedDescription) }
        }
    }

    /// Certificate registration, then tunnel enrolment. Everything here is
    /// idempotent on the server: the same certificate overwrites the same
    /// file, and the same public key rewrites the same record.
    private func registerAndEnrol(
        plane: BoomioPlane,
        certificate: BoomioClientCertificate,
        token: String,
        run: Int
    ) async throws {
        let api = BoomioAPI(plane: plane)
        let identity = BoomioClientIdentity.shared

        try Task.checkCancellation()
        guard isCurrent(run) else { return }
        stage = .registering
        let reply = try await api.registerCertificate(
            pem: certificate.pem,
            fingerprint: identity.hardwareFingerprint,
            sessionToken: token
        )
        guard isCurrent(run) else { return }
        certificateFingerprint = reply.fingerprint_sha256
        // The edge lists the leaf from here on, so later requests may present
        // it. `markRegistered` waits out the edge's allow-list cache.
        if let host = plane.expectedServiceHost {
            identity.markRegistered(host: host)
        }

        try Task.checkCancellation()
        guard isCurrent(run) else { return }
        stage = .enrolling
        let keys = try WireGuardKeypair.loadOrCreate()
        devicePublicKey = keys.publicKeyBase64
        try await api.enrol(publicKey: keys.publicKeyBase64, sessionToken: token)
        let status = try await api.enrolStatus(sessionToken: token)

        try Task.checkCancellation()
        guard isCurrent(run) else { return }
        tunnelAddress = status.address ?? status.lan_endpoint
        serverPublicKey = status.server_pubkey
        endpoint = status.endpoint ?? status.lan_endpoint
        stage = .ready
    }

    /// Polls until the human approves, the code expires, or the task is
    /// cancelled. Returns nil only for cancellation.
    private func waitForApproval(api: BoomioAPI, challenge: BoomioAPI.PairChallenge) async throws -> String? {
        let interval = max(2, min(challenge.interval, 10))
        let deadline = Date().addingTimeInterval(TimeInterval(max(30, challenge.expires_in)))

        while Date() < deadline {
            if Task.isCancelled { return nil }
            try await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return nil }

            let poll = try await api.pollPairing(deviceCode: challenge.device_code)
            if poll.status == "ok", let token = poll.session_token, !token.isEmpty {
                return token
            }
            if poll.status == "expired" {
                throw AuthError(message: "the code expired before it was approved", statusCode: nil)
            }
        }
        throw AuthError(message: "the code expired before it was approved", statusCode: nil)
    }

    // MARK: - Session

    private func isCurrent(_ run: Int) -> Bool { runId == run }

    /// The session is per box: a TV moved to another box must not present the
    /// old box's token there.
    private static func sessionAccount(for plane: BoomioPlane) -> String? {
        guard let host = plane.expectedServiceHost else { return nil }
        return "overlay.session." + host
    }

    private func clearSession() {
        sessionToken = nil
        // Presentation rides on the same trust as the session: a 401/403
        // means the box no longer knows this device, so the leaf it would
        // present may already be refused by the edge. Pairing and
        // re-registration both work certless.
        BoomioClientIdentity.shared.suspendPresentation()
        if let account = sessionAccount {
            BoomioSecureStore.remove(account)
        }
    }
}

// MARK: - Tunnel keypair

/// X25519 keypair for the (unusable on tvOS) WireGuard tunnel.
///
/// The private half is generated once and kept in the Keychain: the box
/// associates the device with this public key at enrolment, so re-minting it
/// would present a new device on every launch.
struct WireGuardKeypair {
    private static let privateAccount = "wg.private.v1"

    let publicKeyBase64: String

    static func loadOrCreate() throws -> WireGuardKeypair {
        if let stored = BoomioSecureStore.string(privateAccount),
           let raw = Data(base64Encoded: stored),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return WireGuardKeypair(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
        }

        let key = Curve25519.KeyAgreement.PrivateKey()
        BoomioSecureStore.save(key.rawRepresentation.base64EncodedString(), account: privateAccount)
        return WireGuardKeypair(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
    }
}
