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
//  Two browsers run side by side on purpose. `NWBrowser` is the modern API,
//  but on tvOS it can sit in `.setup`/`.ready` and never report anything
//  while the wire shows no query at all — and tvOS has no local-network
//  permission (Apple's TN3179 implements it on iOS/iPadOS/visionOS/macOS
//  only), so there is no prompt to blame and no error to show. The older
//  `NetServiceBrowser` rides a different code path onto mDNSResponder; if
//  one finds the box and the other does not, that tells us which layer is
//  broken. `diagnostics` carries what both of them are doing, so the login
//  screen can say it instead of spinning forever.
//

import Combine
import Foundation
import Network

/// Boomio: publishes `@Published` state that is only ever mutated on the main
/// actor (both browsers run on the main run loop and every handler hops with
/// `Task { @MainActor in … }`), so the class itself is not actor-isolated and
/// can be created from a SwiftUI `@StateObject` initialiser.
///
/// `NSObject` because `NetServiceBrowser` needs an Objective-C delegate.
final class LocalServerDiscovery: NSObject, ObservableObject {
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
    /// Set when a browser itself fails. The UI shows it instead of silently
    /// listing nothing.
    @Published private(set) var failureMessage: String?
    /// One line of live state for both browsers, e.g.
    /// `nw ready/0 · ns found 1/1 · 14:22:03`. Nothing else on tvOS can show
    /// whether the browse ever reached the mDNS daemon.
    @Published private(set) var diagnostics: String = ""
    /// Second line: what the first result from each browser actually looked
    /// like (endpoint, whether it carried a TXT, and the TXT's `svc`). The
    /// search can fail in three places — nothing delivered, delivered with no
    /// TXT, delivered but unusable — and only this tells them apart.
    @Published private(set) var detail: String = ""

    private var browser: NWBrowser?
    private var netBrowser: NetServiceBrowser?
    /// Retains what `NetServiceBrowser` hands us; a service that is released
    /// before its delegate call returns is simply gone.
    private var netServices: [String: NetService] = [:]

    private var nwBoxes: [String: Box] = [:]
    private var nsBoxes: [String: Box] = [:]

    private var nwState = "idle"
    private var nsState = "idle"
    private var nwHits = 0
    /// Results handed over by NWBrowser, before any filtering by `box(from:)`.
    private var nwRaw = 0
    private var nwDetail = ""
    private var nsDetail = ""

    // MARK: - Lifecycle

    func start() {
        guard browser == nil, netBrowser == nil else { return }
        failureMessage = nil
        nwBoxes.removeAll()
        nsBoxes.removeAll()
        netServices.removeAll()
        nwState = "starting"
        nsState = "starting"
        nwHits = 0
        publishDiagnostics()

        startNetworkBrowser()
        startNetServiceBrowser()
        isSearching = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        netBrowser?.stop()
        netBrowser = nil
        netServices.removeAll()
        nwBoxes.removeAll()
        nsBoxes.removeAll()
        isSearching = false
        nwState = "stopped"
        nsState = "stopped"
        nwHits = 0
        publishDiagnostics()
    }

    func restart() {
        stop()
        boxes = []
        failureMessage = nil
        start()
    }

    // MARK: - Network.framework browser

    private func startNetworkBrowser() {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.nwState = Self.describe(state)
                switch state {
                case .ready:
                    self.isSearching = true
                    self.failureMessage = nil
                case .waiting(let error):
                    // Kept in `.waiting` rather than failing, and it never
                    // produces a result. Surface it instead of spinning.
                    self.isSearching = true
                    self.failureMessage = Self.message(for: error, source: "Network.framework")
                case .failed(let error):
                    self.isSearching = false
                    self.failureMessage = Self.message(for: error, source: "Network.framework")
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
                self.publishDiagnostics()
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

    private func apply(_ results: Set<NWBrowser.Result>) {
        var next: [String: Box] = [:]
        for result in results {
            guard let box = Self.box(from: result), next[box.id] == nil else { continue }
            next[box.id] = box
        }
        nwBoxes = next
        nwHits = next.count
        nwRaw = results.count
        nwDetail = results.first.map(Self.describe) ?? "none"
        recomputeBoxes()
        publishDiagnostics()
    }

    // MARK: - NetServiceBrowser (independent second path)

    private func startNetServiceBrowser() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType + ".", inDomain: "")
        self.netBrowser = browser
    }

    // MARK: - Merged results

    private func recomputeBoxes() {
        // Network.framework results win when both paths find the same box:
        // they carry the endpoint the system resolved.
        var byURL: [String: Box] = [:]
        for box in nwBoxes.values where byURL[box.backendURL] == nil {
            byURL[box.backendURL] = box
        }
        for box in nsBoxes.values where byURL[box.backendURL] == nil {
            byURL[box.backendURL] = box
        }
        boxes = byURL.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func publishDiagnostics() {
        diagnostics = "nw \(nwState) raw\(nwRaw) box\(nwHits) · ns \(nsState) · \(Self.clock.string(from: Date()))"
        let lines = [nwDetail, nsDetail].filter { !$0.isEmpty }
        detail = lines.joined(separator: "\n")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Advert parsing

    private static func describe(_ state: NWBrowser.State) -> String {
        switch state {
        case .setup:
            return "setup"
        case .ready:
            return "ready"
        case .waiting(let error):
            return "waiting \(error)"
        case .failed(let error):
            return "failed \(error)"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }

    private static func message(for error: NWError, source: String) -> String {
        if case let .dns(code) = error, code == -65555 {
            return "\(source): local-network access denied (DNS -65555)."
        }
        return "\(source): \(error)"
    }

    private static func box(from result: NWBrowser.Result) -> Box? {
        guard case let .bonjour(record) = result.metadata else { return nil }
        var values: [String: String] = [:]
        for key in ["svc", "lan", "pk"] {
            if let value = txt(record, key) { values[key] = value }
        }
        return box(instance: instanceName(result), txt: values)
    }

    /// Builds a box from the advert's TXT values. Both browsers land here, so
    /// the URL the login screen offers does not depend on which one answered.
    private static func box(instance: String?, txt values: [String: String]) -> Box? {
        let systemName = values["svc"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lan = values["lan"]?.trimmingCharacters(in: .whitespacesAndNewlines)

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
            id: label,
            name: label,
            backendURL: backendURL,
            lanAddress: (lan?.isEmpty == false) ? lan : nil,
            serverPublicKey: values["pk"]
        )
    }

    private static func instanceName(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    /// One-line account of a raw browse result: the endpoint it names and
    /// whether it carried a TXT record (and what `svc`/`lan` it held). A result
    /// with no TXT cannot be turned into a box, and this is the only way to see
    /// that from the TV.
    private static func describe(_ result: NWBrowser.Result) -> String {
        var parts: [String] = []
        if case let .service(name, type, domain, _) = result.endpoint {
            parts.append("svc=\(name) \(type) \(domain)")
        } else {
            parts.append("ep=\(result.endpoint)")
        }
        switch result.metadata {
        case .bonjour(let record):
            let svc = txt(record, "svc") ?? "<nil>"
            let lan = txt(record, "lan") ?? "<nil>"
            parts.append("txt svc=\(svc) lan=\(lan)")
        case .none:
            parts.append("txt NONE")
        @unknown default:
            parts.append("txt ?")
        }
        return parts.joined(separator: " · ")
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

    /// DNS TXT data as returned by `NetService.txtRecordData()`: a sequence of
    /// length-prefixed `key=value` strings.
    private static func parseTXT(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        let bytes = [UInt8](data)
        var values: [String: String] = [:]
        var i = 0
        while i < bytes.count {
            let length = Int(bytes[i])
            i += 1
            guard length > 0, i + length <= bytes.count else { break }
            let chunk = Data(bytes[i..<(i + length)])
            i += length
            guard let entry = String(data: chunk, encoding: .utf8) else { continue }
            if let separator = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<separator])
                let value = String(entry[entry.index(after: separator)...])
                values[key] = value
            }
        }
        return values
    }
}

// MARK: - NetServiceBrowserDelegate

extension LocalServerDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            self.nsState = "searching"
            self.publishDiagnostics()
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in
            self.nsState = "stopped"
            self.publishDiagnostics()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in
            let code = errorDict[NetService.errorCode]?.intValue ?? 0
            self.nsState = "error \(code)"
            self.publishDiagnostics()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let name = service.name
        let txtData = service.txtRecordData()
        let values = Self.parseTXT(txtData)
        let txtBytes = txtData.map { "\($0.count)B" } ?? "nil"
        // Retained here, synchronously: a NetService released before its
        // resolve finishes simply stops, and the delegate was weak.
        netServices[name] = service
        Task { @MainActor in
            if let box = Self.box(instance: name, txt: values) {
                self.nsBoxes[box.id] = box
            }
            self.nsDetail = "ns \"\(name)\" txt=\(txtBytes) keys=\(values.count)"
            self.nsState = "found \(self.nsBoxes.count)"
            self.recomputeBoxes()
            self.publishDiagnostics()
        }
        // A browse result carries the PTR's instance name only. The TXT is a
        // separate record and mDNSResponder will not fetch it on our behalf:
        // the wire shows the TV asking for the PTR and nothing else, so
        // `txtRecordData()` here is nil and no box can be built. Resolving by
        // name asks for SRV+TXT explicitly, which is the only way to get `svc`.
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let txtData = sender.txtRecordData()
        let values = Self.parseTXT(txtData)
        let txtBytes = txtData.map { "\($0.count)B" } ?? "nil"
        let host = sender.hostName ?? "no-host"
        netServices[name] = sender
        Task { @MainActor in
            if let box = Self.box(instance: name, txt: values) {
                self.nsBoxes[box.id] = box
                self.nsDetail = "ns \"\(name)\" resolved \(host) txt=\(txtBytes)"
            } else {
                self.nsDetail = "ns \"\(name)\" resolved \(host), no svc/lan txt=\(txtBytes)"
            }
            self.nsState = "found \(self.nsBoxes.count)"
            self.recomputeBoxes()
            self.publishDiagnostics()
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let name = sender.name
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        Task { @MainActor in
            self.nsDetail = "ns \"\(name)\" didNotResolve \(code)"
            self.publishDiagnostics()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor in
            self.netServices[name] = nil
            self.nsBoxes.removeValue(forKey: name)
            self.nsState = "found \(self.nsBoxes.count)"
            self.recomputeBoxes()
            self.publishDiagnostics()
        }
    }
}
