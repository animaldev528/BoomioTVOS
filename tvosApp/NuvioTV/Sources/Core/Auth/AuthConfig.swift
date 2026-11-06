//
//  AuthConfig.swift
//  NuvioTV
//
//  Backend credentials for the account API.
//

import Foundation

/// Account API credentials.
///
/// Boomio: **no backend is baked in.** The box is found on the LAN
/// (`_boomio-overlay._udp`, see `LocalServerDiscovery`) or its URL is typed in,
/// then verified through `/.well-known/nuvio` and saved in
/// `ServerConfigurationStore` — the same path as any self-hosted server. Until
/// that happens `currentConfiguration` is empty and `isConfigured` is false, so
/// sign-in is refused instead of silently pointing at somebody else's server.
enum AuthConfig {
    private static var active: ServerConfiguration? { ServerConfigurationStore().configuration }

    static var currentConfiguration: ServerConfiguration {
        active ?? ServerConfiguration(
            backendURL: "",
            publishableKey: "",
            capabilities: ServerCapabilities(),
            discoveryURL: nil
        )
    }

    static var apiBaseURL: String { currentConfiguration.normalizedBackendURL }
    static var publishableKey: String { currentConfiguration.publishableKey }
    static var capabilities: ServerCapabilities { currentConfiguration.capabilities }
    static var isCustom: Bool { active != nil }
    static var backendIdentity: String { normalizedAPIBaseURL }
    static var avatarPublicBaseURL: String { normalizedAPIBaseURL + "/storage/v1/object/public/avatars" }
    static var storageBaseURL: String { normalizedAPIBaseURL + "/storage/v1" }

    static var apiKey: String { publishableKey }

    /// Base URL the phone opens to approve a TV login. The backend ultimately
    /// returns the real `web_url` to encode in the QR code, so this is only a
    /// fallback hint.
    static var tvLoginWebBaseURL: String {
        currentConfiguration.normalizedBackendURL + "/tv-login"
    }

    static var isConfigured: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var normalizedAPIBaseURL: String {
        var url = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}
