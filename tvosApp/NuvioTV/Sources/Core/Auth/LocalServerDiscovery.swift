//
//  LocalServerDiscovery.swift
//  NuvioTV
//
//  Boomio: finds Boomio boxes on the local network. The box publishes
//  `_boomio-overlay._udp` with avahi-publish-service
//  (overlay/systemd/boomio-overlay-mdns.service); the tuple and its rules live
//  in `OverlayAdvert`.
//
//  Three things this deliberately does NOT do:
//
//   * It does not trust an advert. `svc` is an identity, but DNS is spoofable,
//     so the discovered URL is fed through `ServerDiscoveryService`
//     (/.well-known/nuvio) exactly like a typed one, and the user confirms it.
//   * It does not pick when there is a choice. Two distinct advertised
//     identities means two boxes; guessing which one belongs to this user is
//     how a TV ends up paired with a neighbour's server.
//   * It does not let discovery override a server the user chose by hand. When
//     a host is configured, only adverts naming that host are offered.
//
//  Two browsers run on purpose. `NWBrowser` is the modern API; `NetService`
//  is the older path onto mDNSResponder, and on tvOS it is the one whose
//  explicit `resolve` actually fetches SRV/TXT — a browse alone carries the
//  PTR's instance name and no TXT at all, which is why an un-resolved browse
//  yields a name with nothing usable behind it.
//

import Combine
import Foundation
import Network

final class LocalServerDiscovery: NSObject, ObservableObject {
    struct Box: Identifiable, Equatable {
        /// The advertised service name — the box's identity on the LAN.
        let id: String
        /// Display label ("Boomio overlay").
        let name: String
        /// `https://<svc>`: the certificate is issued for this name.
        let backendURL: String
        let lanAddress: String?
        let serverPublicKey: String?

        var detail: String { lanAddress ?? backendURL }
    }

    @Published private(set) var boxes: [Box] = []
    @Published private(set) var isSearching = false
    /// Set when a browser itself fails. The UI shows it instead of spinning.
    @Published private(set) var failureMessage: String?
    /// Two or more distinct boxes answered. The caller must make the user
    /// choose rather than guessing.
    @Published private(set) var conflictMessage: String?
    /// One line of live state, e.g. `nw ready raw1 box1 · ns found 1/1 · 03:18:44`.
    @Published private(set) var diagnostics: String = ""
    /// What the last result actually contained — the only way to tell "nothing
    /// arrived" from "arrived, refused".
    @Published private(set) var detail: String = ""

    /// When set, only adverts naming this host are offered (the user already
    /// chose a server). Published so the "show every box" affordance follows
    /// it rather than waiting for the next browse event.
    @Published var configuredHost: String?

    private var browser: NWBrowser?
    private var netBrowser: NetServiceBrowser?
    private var netServices: [String: NetService] = [:]

    private var nwBoxes: [String: Box] = [:]
    private var nsBoxes: [String: Box] = [:]

    private var nwState = "idle"
    private var nsState = "idle"
    private var nwHits = 0
    private var nwRaw = 0
    private var nwDetail = ""
    private var nsDetail = ""

    // MARK: - Lifecycle

    func start() {
        guard browser == nil, netBrowser == nil else { return }
        failureMessage = nil
        conflictMessage = nil
        nwBoxes.removeAll()
        nsBoxes.removeAll()
        netServices.removeAll()
        nwState = "starting"
        nsState = "starting"
        nwHits = 0
        nwRaw = 0
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
        nwRaw = 0
        publishDiagnostics()
    }

    func restart() {
        stop()
        boxes = []
        failureMessage = nil
        conflictMessage = nil
        start()
    }

    // MARK: - Network.framework browser

    private func startNetworkBrowser() {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false

        let browser = NWBrowser(for: .bonjour(type: OverlayAdvert.serviceType, domain: nil), using: parameters)
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
            guard let box = Self.box(from: result, configuredHost: configuredHost) else { continue }
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
        browser.searchForServices(ofType: OverlayAdvert.serviceType + ".", inDomain: "")
        self.netBrowser = browser
    }

    // MARK: - Merged results

    private func recomputeBoxes() {
        // Identity is the advertised `svc`, not the instance name: avahi
        // re-announces under the same name, and two instances that advertise
        // the same box are one box.
        var byService: [String: Box] = [:]
        for box in nwBoxes.values.sorted(by: { $0.id < $1.id }) where byService[box.id] == nil {
            byService[box.id] = box
        }
        for box in nsBoxes.values.sorted(by: { $0.id < $1.id }) where byService[box.id] == nil {
            byService[box.id] = box
        }

        let merged = byService.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        boxes = merged

        if merged.count > 1 {
            conflictMessage = "More than one Boomio box is advertising on this network. Choose the one you trust."
        } else {
            conflictMessage = nil
        }
    }

    private func publishDiagnostics() {
        diagnostics = "nw \(nwState) raw\(nwRaw) box\(nwHits) · ns \(nsState) · \(Self.clock.string(from: Date()))"
        let lines = [nwDetail, nsDetail].filter { !$0.isEmpty }
        detail = lines.joined(separator: "\n")
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
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
            return "\(source): the system refused the local-network browse (DNS -65555)."
        }
        return "\(source): \(error)"
    }

    private static func box(from result: NWBrowser.Result, configuredHost: String?) -> Box? {
        guard case let .bonjour(record) = result.metadata else { return nil }
        // Re-assembled as `key=value` strings so this path goes through the
        // SAME parser as the NetService and DNS-TXT paths: the semicolon
        // framing rule and the v==2/svc gates then cannot differ per browser.
        var strings: [String] = []
        for key in ["v", "svc", "lan", "pk"] {
            if let value = txt(record, key) { strings.append("\(key)=\(value)") }
        }
        return box(
            instance: instanceName(result),
            advert: OverlayAdvert.parse(txtStrings: strings),
            configuredHost: configuredHost
        )
    }

    /// Builds a box from an advert. Every browser lands here, so the URL the
    /// login screen offers never depends on which one answered.
    private static func box(instance: String?, advert: OverlayAdvert?, configuredHost: String?) -> Box? {
        guard let advert, advert.matches(configuredHost: configuredHost) else { return nil }

        let host = advert.preferredHost
        guard let url = URL(string: "https://" + host), url.host != nil else { return nil }
        var backendURL = url.absoluteString
        while backendURL.hasSuffix("/") { backendURL.removeLast() }

        let label = (instance?.isEmpty == false ? instance : nil) ?? host
        return Box(
            id: advert.serviceName,
            name: label,
            backendURL: backendURL,
            lanAddress: advert.lanHost,
            serverPublicKey: advert.serverPublicKey
        )
    }

    private static func instanceName(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    /// One-line account of a raw browse result: the endpoint it names and
    /// whether it carried a TXT. A result with no TXT cannot become a box.
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
            let version = txt(record, "v") ?? "<nil>"
            parts.append("txt v=\(version) svc=\(svc)")
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
    /// length-prefixed strings.
    private static func parseTXT(_ data: Data?) -> [String] {
        guard let data else { return [] }
        let bytes = [UInt8](data)
        var strings: [String] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard length > 0, index + length <= bytes.count else { break }
            if let entry = String(data: Data(bytes[index..<(index + length)]), encoding: .utf8) {
                strings.append(entry)
            }
            index += length
        }
        return strings
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
        let strings = Self.parseTXT(service.txtRecordData())
        let bytes = service.txtRecordData().map { "\($0.count)B" } ?? "nil"
        // Retained synchronously: a NetService released before its resolve
        // finishes simply stops, and the delegate is weak.
        netServices[name] = service

        Task { @MainActor in
            if let box = Self.box(
                instance: name,
                advert: OverlayAdvert.parse(txtStrings: strings),
                configuredHost: self.configuredHost
            ) {
                self.nsBoxes[box.id] = box
            }
            self.nsDetail = "ns \"\(name)\" txt=\(bytes) fields=\(strings.count)"
            self.nsState = "found \(self.nsBoxes.count)"
            self.recomputeBoxes()
            self.publishDiagnostics()
        }

        // A browse result carries the PTR's instance name only. mDNSResponder
        // will not fetch the TXT on our behalf, so this resolve is what asks
        // for SRV+TXT — without it `txtRecordData()` stays nil forever.
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let strings = Self.parseTXT(sender.txtRecordData())
        let host = sender.hostName ?? "no-host"
        netServices[name] = sender

        Task { @MainActor in
            if let box = Self.box(
                instance: name,
                advert: OverlayAdvert.parse(txtStrings: strings),
                configuredHost: self.configuredHost
            ) {
                self.nsBoxes[box.id] = box
                self.nsDetail = "ns \"\(name)\" resolved \(host) fields=\(strings.count)"
            } else {
                self.nsDetail = "ns \"\(name)\" resolved \(host), advert refused"
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
}
