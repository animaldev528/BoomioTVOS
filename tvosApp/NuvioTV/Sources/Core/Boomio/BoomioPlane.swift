//
//  BoomioPlane.swift
//  NuvioTV
//
//  Boomio: where each plane lives, derived from the ONE server the user chose.
//
//  The box serves every plane from a single origin, told apart by path prefix
//  (caddy/planes/boomio-collapse.caddy):
//
//      /auth/v1, /rest/v1, /functions/v1   -> the Nuvio backend (Supabase)
//      /bsc/*                              -> the overlay/companion API
//      /bsf/*                              -> the media plane
//      /bsm/*                              -> the device manager
//
//  `/.well-known/nuvio` advertises only `backend_url`, so the prefixes are
//  derived here, once. Everything that talks to the box (discovery, pairing,
//  certificate registration, enrolment, playback) asks this type for its URL
//  instead of composing one inline — a second composition is a second place
//  for the prefix to drift.
//

import Foundation

struct BoomioPlane: Equatable {
    /// Scheme + host + port, with no trailing slash.
    let serviceOrigin: URL

    /// Overlay/companion API, e.g. `https://boomio.duckdns.org/bsc/api`.
    var apiBase: URL { Self.append(serviceOrigin, "bsc/api") }

    /// Media plane, e.g. `https://boomio.duckdns.org/bsf`.
    var mediaBase: URL { Self.append(serviceOrigin, "bsf") }

    /// Builds a plane from a validated backend URL.
    ///
    /// - Parameter overlayURL: an explicit service origin when the discovery
    ///   document advertises one. Absent today, so the backend's own origin is
    ///   used — which is correct for every single-origin deployment and is why
    ///   one typed URL is enough.
    init?(backendURL: URL, overlayURL: URL? = nil) {
        guard let origin = Self.origin(of: overlayURL ?? backendURL) else { return nil }
        self.serviceOrigin = origin
    }

    /// The host a discovery advert must name to be considered this server.
    var expectedServiceHost: String? { serviceOrigin.host?.lowercased() }

    private static func origin(of url: URL) -> URL? {
        // HTTPS only. The enrolment calls carry a `bs_ses_…` bearer and, in
        // the other direction, prove identity with a client certificate; over
        // http the bearer is readable on the wire and the certificate proves
        // nothing. A box that cannot serve TLS cannot enrol this device.
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        // A path on the input is deliberately dropped: the planes are prefixes
        // of the origin, and `https://box/bsc` in the field must not become
        // `https://box/bsc/bsc/api`.
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func append(_ base: URL, _ path: String) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + "/" + path) ?? base
    }
}
