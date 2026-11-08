//
//  BoomioParityTests.swift
//  NuvioTVTests
//
//  Pins the parts of the Boomio client that are a CONTRACT with the server and
//  therefore must not drift: the certificate CN algorithm (the box recomputes
//  it and refuses a mismatch), and the advert/plane parsing that decides which
//  box a TV talks to.
//

import XCTest
@testable import NuvioTV

final class BoomioParityTests: XCTestCase {

    // MARK: - Certificate CN (mirrors bsc/lib/overlay-store.js peerNameFor)

    func testPeerNameMatchesServerVectors() {
        XCTAssertEqual(
            BoomioDeviceName.peerName(forDeviceId: "nuvio-tvos-0f9a1c2e-1234-4abc-9def-0123456789ab"),
            "device-nuvio-tvos-0f9a1c2e-1234-4abc-9d-2bc581c3"
        )
        XCTAssertEqual(
            BoomioDeviceName.peerName(forDeviceId: "probe-tvos-plan-0001"),
            "device-probe-tvos-plan-0001-d974cd29"
        )
    }

    func testPeerNameUppercasesFoldBeforeSlugging() {
        // The tag hashes the ORIGINAL id, but the slug is lowercased.
        let upper = BoomioDeviceName.peerName(forDeviceId: "Nuvio-TVOS-ABC")
        let lower = BoomioDeviceName.peerName(forDeviceId: "nuvio-tvos-abc")
        XCTAssertEqual(upper.split(separator: "-").dropLast().joined(separator: "-"),
                       lower.split(separator: "-").dropLast().joined(separator: "-"))
        XCTAssertNotEqual(upper, lower, "the tag hashes the raw id, so case changes it")
    }

    func testPeerNameCollapsesRunsAndTrims() {
        // Runs of disallowed characters become ONE dash, leading non-alnum is
        // stripped, and a trailing dash/dot is removed after truncation.
        let name = BoomioDeviceName.peerName(forDeviceId: "  --..//tvos box!!  ")
        XCTAssertTrue(name.hasPrefix("device-tvos-box-"), name)
        XCTAssertFalse(name.hasSuffix("-"))
        XCTAssertFalse(name.contains("--"))
    }

    func testPeerNameTruncatesSlugTo32Characters() {
        let long = String(repeating: "a", count: 80)
        let name = BoomioDeviceName.peerName(forDeviceId: long)
        let slug = name.replacingOccurrences(of: "device-", with: "")
        // 32 characters of slug + '-' + 8 characters of tag.
        XCTAssertEqual(slug.count, 32 + 1 + 8)
    }

    func testPeerNameHasNoSlugWhenEverythingIsStripped() {
        let name = BoomioDeviceName.peerName(forDeviceId: "!!!")
        XCTAssertTrue(name.hasPrefix("device-"), name)
        // `device-<tag>` only: no second dash.
        XCTAssertEqual(name.filter { $0 == "-" }.count, 1)
    }

    func testHardwareFingerprintIsStableAnd32Hex() {
        let id = UUID(uuidString: "8A4F2C1B-1111-2222-3333-444455556666")!
        let first = BoomioDeviceName.hardwareFingerprint(vendorIdentifier: id)
        let second = BoomioDeviceName.hardwareFingerprint(vendorIdentifier: id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Overlay advert

    private func advert(_ txt: [String: String]) -> OverlayAdvert? {
        OverlayAdvert.parse(txt: txt)
    }

    func testAdvertParsesAV2Tuple() throws {
        let parsed = try XCTUnwrap(advert([
            "v": "2",
            "svc": "boomio.duckdns.org",
            "lan": "192.168.68.65",
            "wan": "203.0.113.7",
            "port": "51820",
            "pport": "51821",
            "pk": "SERVERPUBKEY",
            "ppk": "PROVPUBKEY",
            "prov": "1",
        ]))
        XCTAssertEqual(parsed.serviceName, "boomio.duckdns.org")
        XCTAssertEqual(parsed.lanHost, "192.168.68.65")
        XCTAssertEqual(parsed.port, 51820)
        XCTAssertEqual(parsed.provisioningPort, 51821)
        XCTAssertTrue(parsed.provisioningEnabled)
        XCTAssertEqual(parsed.serverPublicKey, "SERVERPUBKEY")
        XCTAssertEqual(parsed.preferredHost, "boomio.duckdns.org")
    }

    func testAdvertRefusedWithoutVersion2() {
        XCTAssertNil(advert(["svc": "boomio.duckdns.org"]), "no v= is refused whole")
        XCTAssertNil(advert(["v": "1", "svc": "boomio.duckdns.org"]))
        XCTAssertNil(advert(["v": "3", "svc": "boomio.duckdns.org"]))
        XCTAssertNil(advert(["v": "two", "svc": "boomio.duckdns.org"]))
    }

    func testAdvertRefusedWithoutServiceIdentity() {
        XCTAssertNil(advert(["v": "2"]))
        XCTAssertNil(advert(["v": "2", "svc": ""]))
        XCTAssertNil(advert(["v": "2", "svc": "   "]))
        // Something that cannot be a host at all.
        XCTAssertNil(advert(["v": "2", "svc": "not a host"]))
    }

    func testAdvertDefaultsProvisioningPortToTunnelPort() throws {
        let parsed = try XCTUnwrap(advert(["v": "2", "svc": "box.lan", "port": "60000"]))
        XCTAssertEqual(parsed.provisioningPort, 60000)
        XCTAssertFalse(parsed.provisioningEnabled)
        let noPort = try XCTUnwrap(advert(["v": "2", "svc": "box.lan"]))
        XCTAssertEqual(noPort.port, OverlayAdvert.defaultPort)
    }

    func testSemicolonSplitStopsFieldFusion() {
        // `"svc=a;lan="` followed by `"1.2.3.4"` must NOT produce lan=1.2.3.4:
        // the empty value stays empty and the orphan is ignored.
        let parsed = OverlayAdvert.parse(txtStrings: ["v=2;svc=box.lan;lan=", "1.2.3.4"])
        XCTAssertEqual(parsed?.serviceName, "box.lan")
        XCTAssertNil(parsed?.lanHost)
    }

    func testFirstDuplicateWins() {
        let parsed = OverlayAdvert.parse(txtStrings: ["v=2", "svc=first.lan", "svc=second.lan"])
        XCTAssertEqual(parsed?.serviceName, "first.lan")
    }

    func testAdvertIdentityGate() throws {
        let parsed = try XCTUnwrap(advert(["v": "2", "svc": "boomio.duckdns.org"]))
        XCTAssertTrue(parsed.matches(configuredHost: nil), "no configured server accepts any parsed advert")
        XCTAssertTrue(parsed.matches(configuredHost: ""))
        XCTAssertTrue(parsed.matches(configuredHost: "boomio.duckdns.org"))
        XCTAssertTrue(parsed.matches(configuredHost: "BOOMIO.DUCKDNS.ORG"), "hosts compare case-insensitively")
        XCTAssertFalse(parsed.matches(configuredHost: "neighbour.duckdns.org"))
    }

    // MARK: - Plane derivation (one address, every plane)

    func testPlaneDerivesEveryPlaneFromOneOrigin() throws {
        let plane = try XCTUnwrap(BoomioPlane(backendURL: URL(string: "https://boomio.duckdns.org")!))
        XCTAssertEqual(plane.serviceOrigin.absoluteString, "https://boomio.duckdns.org")
        XCTAssertEqual(plane.apiBase.absoluteString, "https://boomio.duckdns.org/bsc/api")
        XCTAssertEqual(plane.mediaBase.absoluteString, "https://boomio.duckdns.org/bsf")
        XCTAssertEqual(plane.expectedServiceHost, "boomio.duckdns.org")
    }

    func testPlaneDropsAPathFromTheInput() throws {
        // Pasting the backend URL (or `/bsc`) must not produce
        // `https://box/bsc/bsc/api`.
        let plane = try XCTUnwrap(BoomioPlane(backendURL: URL(string: "https://box.lan/bsc/")!))
        XCTAssertEqual(plane.apiBase.absoluteString, "https://box.lan/bsc/api")
    }

    func testPlaneKeepsAnExplicitPort() throws {
        let plane = try XCTUnwrap(BoomioPlane(backendURL: URL(string: "https://box.lan:8443/auth/v1")!))
        XCTAssertEqual(plane.serviceOrigin.absoluteString, "https://box.lan:8443")
        XCTAssertEqual(plane.mediaBase.absoluteString, "https://box.lan:8443/bsf")
    }

    func testPlaneRefusesNonHTTPSchemes() {
        XCTAssertNil(BoomioPlane(backendURL: URL(string: "ftp://box.lan")!))
        XCTAssertNil(BoomioPlane(backendURL: URL(string: "file:///etc/passwd")!))
    }

    func testPlaneRefusesCleartextHTTP() {
        // The enrolment bearer and the client certificate are only meaningful
        // over TLS; accepting http here would put the session token on the
        // wire and make the certificate attest nothing.
        XCTAssertNil(BoomioPlane(backendURL: URL(string: "http://box.lan")!))
        XCTAssertNil(BoomioPlane(backendURL: URL(string: "HTTP://BOX.LAN:8080")!), "scheme check is case-insensitive")
    }
}
