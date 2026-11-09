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
//  A challenge is answered only for the client-certificate method, and only
//  when a Keychain identity exists. Everything else is left to the default
//  handling, so this never weakens server trust.
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
}

/// Holds the challenge logic, so it can be constructed before `self` exists.
final class CertificateChallengeDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
              let identity = BoomioClientIdentity.shared.secIdentity()
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(
            .useCredential,
            URLCredential(identity: identity, certificates: nil, persistence: .forSession)
        )
    }
}
