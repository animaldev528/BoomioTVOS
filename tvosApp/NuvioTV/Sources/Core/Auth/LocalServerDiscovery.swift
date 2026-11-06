//
//  LocalServerDiscovery.swift
//  NuvioTV
//
//  Boomio: finds Boomio boxes on the local network. The box publishes
//  `_boomio-overlay._udp` with avahi-publish-service
//  (overlay/systemd/boomio-overlay-mdns.service):
//
//    TXT  v=2 svc=<fqdn> lan=<address> wan=<address> port=… ppord=…
//         pk=<server wg pubkey> ppk=<provisioning pubkey> prov=… addr=10.77.0.1
//
//  `svc` is the FQDN the box is served under, which is what the client can
//  actually reach over HTTPS; `lan` is the address on the local segment.
//
//  The advert is spoofable — only `pk`/`ppk` are authenticated, and only
//  during enrolment. So a discovered URL is never trusted on its own: it is
//  fed through `ServerDiscoveryPolicy` (/.well-known/nuvio) exactly like a
//  typed URL, and the user still has to confirm before it is saved.
//

import Combine
import Foundation
import Network

/// Boomio: publishes `@Published` state that is only ever mutated on the main
/// actor (the browser runs on `.main` and every handler hops with
/// `Task { @MainActor in … }`), so the class itself is not actor-isolated and
/// can be created from a SwiftUI `@StateObject` initialiser.
final class LocalServerDiscovery: ObservableObject {
    struct Box: Identifiable, Equatable {
        /// Bonjour instance name, or the backend URL when the name is absent.
        let id: String
        /// Display label from the advert ("Boomio overlay").
        let name: String
        /// `https://<svc>`, or `https://<lan>` when the box publishes no FQDN.
        let backendURL: String
        let lanAddress: String?
        let serverPublicKey: String?

        var detail: String { lanAddress ?? backendURL }
    }

    static let serviceType = "_boomio-overlay._udp"

    @Published private(set) var boxes: [Box] = []
    @Published private(set) var isSearching = false
    /// Set when the browser itself fails (usually denied local-network
    /// access). The UI shows it instead of silently listing nothing.
    @Published private(set) var failureMessage: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        failureMessage = nil

        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                    self.failureMessage = nil
                case .waiting(let error):
                    // A denied local-network permission does not fail the
                    // browser — it parks in .waiting with DNS policy-denied
                    // (-65555) and never produces a result. Surface it, or
                    // the screen says "Searching…" forever with no clue.
                    self.isSearching = true
                    self.failureMessage = Self.message(for: error)
                case .failed(let error):
                    self.isSearching = false
                    self.failureMessage = Self.message(for: error)
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        isSearching = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    func restart() {
        stop()
        boxes = []
        failureMessage = nil
        start()
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        var next: [Box] = []
        for result in results {
            guard let box = Self.box(from: result), seen.insert(box.backendURL).inserted else { continue }
            next.append(box)
        }
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        boxes = next
    }

    private static func message(for error: NWError) -> String {
        // kDNSServiceErr_PolicyDenied: the app is not allowed to use the
        // local network. tvOS never asks twice, so the way back is to delete
        // and reinstall the app and choose Allow on the prompt.
        if case let .dns(code) = error, code == -65555 {
            return "Apple TV is blocking local-network access for this app. "
                + "Delete the app, reinstall it, and choose Allow when it asks "
                + "to find devices on your network."
        }
        return String(describing: error)
    }

    private static func box(from result: NWBrowser.Result) -> Box? {
        guard case let .bonjour(record) = result.metadata else { return nil }

        let systemName = txt(record, "svc")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lan = txt(record, "lan")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instance = instanceName(result)

        // Prefer the FQDN: the certificate is issued for it, and a bare LAN
        // address will usually fail TLS verification.
        let host: String
        if let systemName, !systemName.isEmpty {
            host = systemName
        } else if let lan, !lan.isEmpty {
            host = lan
        } else {
            return nil
        }

        guard let url = URL(string: "https://" + host), url.host != nil else { return nil }
        var backendURL = url.absoluteString
        while backendURL.hasSuffix("/") { backendURL.removeLast() }

        let label = (instance?.isEmpty == false ? instance : nil) ?? host
        return Box(
            id: instance?.isEmpty == false ? instance! : backendURL,
            name: label,
            backendURL: backendURL,
            lanAddress: (lan?.isEmpty == false) ? lan : nil,
            serverPublicKey: txt(record, "pk")
        )
    }

    private static func instanceName(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private static func txt(_ record: NWTXTRecord, _ key: String) -> String? {
        guard let entry = record.getEntry(for: key) else { return nil }
        switch entry {
        case .string(let value):
            return value
        case .data(let data):
            return String(data: data, encoding: .utf8)
        case .empty:
            return nil
        @unknown default:
            return nil
        }
    }
}
