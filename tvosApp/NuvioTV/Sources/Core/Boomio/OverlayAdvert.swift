//
//  OverlayAdvert.swift
//  NuvioTV
//
//  Boomio: the discovery tuple the box publishes over mDNS, parsed ONCE.
//
//  The advert is a TXT record on `_boomio-overlay._udp`:
//
//      v=2 svc=<fqdn> lan=<ip> wan=<ip> port=51820 pport=51820
//      pk=<server wg pubkey> ppk=<provisioning pubkey> prov=1 addr=10.77.0.1
//
//  Two rules are load-bearing and are why this type refuses rather than
//  repairs (they are the Android client's, and the box depends on them):
//
//   * `v` must be exactly 2. A tuple without it is refused WHOLE — a partially
//     understood advert is more dangerous than none, because the client would
//     fall back to guessed defaults.
//   * `svc` is the identity. A configured server accepts only an advert whose
//     `svc` host is that server, and an advert with no `svc` is refused. mDNS
//     is spoofable; `svc` plus a later certificate check is what stops a rogue
//     advert from silently redirecting a configured TV.
//
//  Both the mDNS path and the DNS-TXT path funnel through `parse(txt:)`, so
//  neither can half-parse an advert the other would refuse.
//

import Foundation

struct OverlayAdvert: Equatable {
    static let serviceType = "_boomio-overlay._udp"
    static let defaultPort = 51820
    static let supportedVersion = 2

    let version: Int
    /// The FQDN the box is served under — the identity gate.
    let serviceName: String
    let lanHost: String?
    let wanHost: String?
    let port: Int
    let provisioningPort: Int
    let provisioningEnabled: Bool
    let serverPublicKey: String?
    let provisioningPublicKey: String?

    /// Whether this advert may be offered for a server the user already chose.
    /// No configured server (`nil` or empty) accepts anything that parsed.
    func matches(configuredHost: String?) -> Bool {
        guard let configuredHost = configuredHost?.lowercased(), !configuredHost.isEmpty else {
            return true
        }
        return URL(string: "https://" + serviceName)?.host?.lowercased() == configuredHost
    }

    /// The address to offer the user: `svc` is what the certificate is issued
    /// for, so it wins; `lan` is the fallback for a box with no public name.
    var preferredHost: String { serviceName }

    static func parse(txt values: [String: String]) -> OverlayAdvert? {
        guard let rawVersion = values["v"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let version = Int(rawVersion), version == supportedVersion
        else { return nil }

        guard let serviceName = values["svc"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serviceName.isEmpty,
              URL(string: "https://" + serviceName)?.host != nil
        else { return nil }

        let port = int(values["port"]) ?? defaultPort
        // `pport` is the provisioning port and defaults to the tunnel's: the
        // box publishes both on 51820, differing only in protocol.
        let provisioningPort = int(values["pport"]) ?? port

        return OverlayAdvert(
            version: version,
            serviceName: serviceName,
            lanHost: trimmed(values["lan"]),
            wanHost: trimmed(values["wan"]),
            port: port,
            provisioningPort: provisioningPort,
            provisioningEnabled: trimmed(values["prov"]) == "1",
            serverPublicKey: trimmed(values["pk"]),
            provisioningPublicKey: trimmed(values["ppk"])
        )
    }

    /// Parses a raw TXT record, whether it arrives as separate strings (mDNS)
    /// or as one blob (a DNS TXT record).
    ///
    /// A string that itself carries `;` is split on it first. That is the
    /// Android client's defence against a record framed across several
    /// strings fusing two fields (`"svc=a;lan=" + "1.2.3.4"` must not produce
    /// `lan=1.2.3.4` when it meant an empty value); an unknown additive field
    /// is simply ignored, which is what makes the tuple extensible.
    static func parse(txtStrings strings: [String]) -> OverlayAdvert? {
        var values: [String: String] = [:]
        for raw in strings {
            for entry in raw.split(separator: ";", omittingEmptySubsequences: true) {
                let text = String(entry)
                guard let separator = text.firstIndex(of: "=") else { continue }
                let key = String(text[text.startIndex..<separator])
                let value = String(text[text.index(after: separator)...])
                // First wins: a later duplicate cannot rewrite an earlier field.
                if values[key] == nil { values[key] = value }
            }
        }
        return parse(txt: values)
    }

    private static func int(_ raw: String?) -> Int? {
        guard let raw = trimmed(raw) else { return nil }
        return Int(raw)
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
