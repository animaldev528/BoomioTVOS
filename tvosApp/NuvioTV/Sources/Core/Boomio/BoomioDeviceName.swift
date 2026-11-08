//
//  BoomioDeviceName.swift
//  NuvioTV
//
//  Boomio: the device name the SERVER will assign, computed locally.
//
//  `POST /api/overlay/cert` refuses a certificate whose CN is not exactly the
//  name the box derives from the *verified session's* device id
//  (bsc/lib/overlay-store.js `peerNameFor`). The device id is client-supplied
//  at pair time and is copied verbatim into the session, so a client that
//  reproduces the algorithm can put the right CN in the certificate it mints
//  before it ever talks to the box. A mismatch is a 400 `cn_mismatch` that
//  looks like a client bug, so the algorithm is duplicated here deliberately
//  and pinned by these vectors:
//
//      nuvio-tvos-0f9a1c2e-1234-4abc-9def-0123456789ab
//          -> device-nuvio-tvos-0f9a1c2e-1234-4abc-9d-2bc581c3
//      probe-tvos-plan-0001
//          -> device-probe-tvos-plan-0001-d974cd29
//
//  Keep this in step with the server. If it ever drifts, registration fails
//  closed with a clear reason rather than silently registering a bad identity.
//

import CryptoKit
import Foundation

enum BoomioDeviceName {
    /// Prefix for the install identifier. The box keys the certificate on this
    /// id, so it must survive relaunches — it lives in the Keychain, not
    /// UserDefaults, which a reinstall clears.
    static let deviceIdPrefix = "nuvio-tvos-"

    /// `device-<slug>-<tag>`, exactly as `peerNameFor` computes it.
    static func peerName(forDeviceId deviceId: String) -> String {
        let raw = deviceId
        let lowered = raw.lowercased()

        // JavaScript: `.replace(/[^a-z0-9_.-]+/g, '-')` — note it collapses a
        // RUN of disallowed characters into one dash, which is why this is not
        // a per-character map.
        var slug = ""
        var inRun = false
        for scalar in lowered.unicodeScalars {
            let allowed = isAllowed(scalar)
            if allowed {
                slug.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                slug.append("-")
                inRun = true
            }
        }

        // `.replace(/^[^a-z0-9]+/, '')`
        while let first = slug.unicodeScalars.first, !isAlphanumeric(first) {
            slug.removeFirst()
        }
        // `.slice(0, 32)` then `.replace(/[-.]+$/, '')`
        slug = String(slug.prefix(32))
        while let last = slug.unicodeScalars.last, last == "-" || last == "." {
            slug.removeLast()
        }

        let digest = SHA256.hash(data: Data(raw.utf8))
        let tag = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return slug.isEmpty ? "device-\(tag)" : "device-\(slug)-\(tag)"
    }

    /// An opaque, stable, 32-hex hardware hint sent alongside the certificate.
    ///
    /// It is only consulted to pick which bsm row the certificate is filed
    /// against, so a wiped box rejoins the row it already had. The server
    /// treats it as unverified and rejects anything that is not 32 hex — hence
    /// the fixed width here rather than a raw UUID string.
    static func hardwareFingerprint(vendorIdentifier: UUID) -> String {
        let digest = SHA256.hash(data: Data(vendorIdentifier.uuidString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        isAlphanumeric(scalar) || scalar == "_" || scalar == "." || scalar == "-"
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        // ASCII only: the server's class is /[a-z0-9]/, not Unicode letters.
        (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
    }
}
