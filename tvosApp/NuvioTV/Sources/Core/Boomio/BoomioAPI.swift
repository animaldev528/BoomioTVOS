//
//  BoomioAPI.swift
//  NuvioTV
//
//  Boomio: the five calls the box offers for pairing and enrolment.
//
//  All of them live under the service plane (`/bsc/api`), on the same origin as
//  the Nuvio backend the user already configured:
//
//      POST /v1/auth/device/request   -> { device_code, user_code, verification_uri, … }
//      GET  /v1/auth/device/poll?dc=  -> { status, session_token, … }
//      POST /overlay/cert             -> register this device's client certificate
//      POST /overlay/enroll           -> { pubkey } -> 202 pending
//      GET  /overlay/enroll/status    -> the tunnel assignment
//
//  Nothing here trusts a reply's shape beyond what it decodes: a missing field
//  is a failed step, not a default, because every one of these answers decides
//  something security-relevant.
//

import Foundation

final class BoomioAPI {
    private let plane: BoomioPlane
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(plane: BoomioPlane, session: URLSession = BoomioSession.shared.session) {
        self.plane = plane
        self.session = session
    }

    // MARK: - Pairing

    struct PairRequest: Encodable {
        let device_id: String
        let platform: String
        let type: String
        let name: String
        let hw_fingerprint: String
        let capabilities: [String: Bool]
    }

    struct PairChallenge: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    struct PairPoll: Decodable {
        let status: String
        let session_token: String?
        let display_name: String?
    }

    func requestPairing(request: PairRequest) async throws -> PairChallenge {
        try await send(path: "v1/auth/device/request", method: "POST", body: request, bearer: nil)
    }

    func pollPairing(deviceCode: String) async throws -> PairPoll {
        try await send(
            path: "v1/auth/device/poll",
            method: "GET",
            query: [URLQueryItem(name: "dc", value: deviceCode)],
            bearer: nil
        )
    }

    // MARK: - Certificate

    struct CertificateRegistration: Encodable {
        let cert: String
        let hw_fingerprint: String
    }

    struct CertificateReply: Decodable {
        let status: String
        let name: String
        let fingerprint_sha256: String
        let not_before: String?
        let not_after: String?
    }

    /// Registers the certificate. The session must be a `bs_ses_…` token.
    func registerCertificate(pem: String, fingerprint: String, sessionToken: String) async throws -> CertificateReply {
        try await send(
            path: "overlay/cert",
            method: "POST",
            body: CertificateRegistration(cert: pem, hw_fingerprint: fingerprint),
            bearer: sessionToken
        )
    }

    // MARK: - Tunnel enrolment

    struct EnrolRequest: Encodable { let pubkey: String }

    struct EnrolAccepted: Decodable { let status: String? }

    struct EnrolStatus: Decodable {
        let status: String
        let name: String?
        let address: String?
        let server_pubkey: String?
        let endpoint: String?
        /// Per-plane targets. `endpoint` is the tunnel's; on a LAN-only box the
        /// useful one is `lan_endpoint`, which the server always fills.
        let lan_endpoint: String?
        let wan_endpoint: String?
        let overlay_cidr: String?
        let mtu: Int?
        let reason: String?
    }

    @discardableResult
    func enrol(publicKey: String, sessionToken: String) async throws -> EnrolAccepted {
        try await send(path: "overlay/enroll", method: "POST", body: EnrolRequest(pubkey: publicKey), bearer: sessionToken)
    }

    func enrolStatus(sessionToken: String) async throws -> EnrolStatus {
        try await send(path: "overlay/enroll/status", method: "GET", bearer: sessionToken)
    }

    // MARK: - Transport

    private struct NoBody: Encodable {}

    private func send<T: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        bearer: String?
    ) async throws -> T {
        try await send(path: path, method: method, query: query, body: Optional<NoBody>.none, bearer: bearer)
    }

    private func send<T: Decodable, B: Encodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: B?,
        bearer: String?
    ) async throws -> T {
        guard var components = URLComponents(url: plane.apiBase, resolvingAgainstBaseURL: false) else {
            throw AuthError(message: "invalid server address", statusCode: nil)
        }
        components.path = components.path + "/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw AuthError(message: "invalid request address", statusCode: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        if let bearer = bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // The box classifies refusals by status (403 revoked, 400 invalid,
            // 500 retryable), so keep both the code and any message it sent.
            let message = (try? decoder.decode(ServerError.self, from: data))?.error
                ?? "server returned \(status)"
            throw AuthError(message: message, statusCode: status)
        }
        return try decoder.decode(T.self, from: data)
    }

    private struct ServerError: Decodable {
        let error: String?
        let code: String?
    }
}
