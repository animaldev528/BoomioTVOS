//
//  BoomioSession.swift
//  NuvioTV
//
//  Boomio: the URLSession that carries the client certificate.
//
//  The box's edge runs with `client_auth { mode request }` — it ASKS for a
//  certificate, refuses nobody, and forwards the presented leaf to bsc/bsf,
//  which is what keys the media plane. So presenting is how a registered
//  certificate turns into access; not presenting simply means requests arrive
//  unkeyed.
//
//  A challenge is answered only for the client-certificate method, only for
//  the enrolled host, and only once the box has accepted the certificate.
//  Everything else is left to the default handling, so this never weakens
//  server trust.
//

import Foundation

final class BoomioSession: NSObject {
    static let shared = BoomioSession()

    let session: URLSession

    private override init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: configuration,
            delegate: CertificateChallengeDelegate(),
            delegateQueue: nil
        )
        super.init()
    }

    /// A session for addon and metadata fetches that must be able to present
    /// the box's device certificate. The identity scopes presentation to the
    /// enrolled host, so a third-party addon server never sees it.
    static let addonSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(
            configuration: configuration,
            delegate: CertificateChallengeDelegate(),
            delegateQueue: nil
        )
    }()
}

/// Holds the challenge logic, so it can be constructed before `self` exists.
final class CertificateChallengeDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // The identity decides, not this delegate: it knows whether the edge
        // has accepted this certificate yet (presenting it before that is a
        // refused handshake) and whether the challenge is even for the
        // enrolled box.
        if let credential = BoomioClientIdentity.shared.clientCredential(for: challenge.protectionSpace) {
            completionHandler(.useCredential, credential)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
