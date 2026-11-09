//
//  BoomioOnboardingView.swift
//  NuvioTV
//
//  Boomio: the one-time setup that makes this Apple TV a known device on the
//  box.
//
//  It is deliberately a separate screen from login. Signing in to the Nuvio
//  backend gets you your library; enrolling gets the box to recognise this
//  device's certificate, which is what the media plane keys on, and what
//  registers the tunnel key. A TV can be signed in and still be a stranger to
//  the box — that is exactly the state that used to produce "container
//  unsupported" from /bsf.
//
//  A single address drives all of it. The box serves the Nuvio backend, the
//  overlay API, the media plane and the device manager from one origin told
//  apart by path prefix, so `BoomioPlane` derives the rest (see BoomioPlane).
//
//  ⚠️ The address is NOT trusted because it was discovered. An mDNS advert is
//  unauthenticated and spoofable, and pairing hands the box this TV's device
//  id, hardware fingerprint and (after approval) a session. So every address —
//  discovered, typed or already configured — goes through the same
//  `/.well-known/nuvio` check the login screen uses, and the user confirms
//  before the first pairing call is made.
//

import SwiftUI

struct BoomioOnboardingView: View {
    let onClose: () -> Void

    private enum Step: Equatable {
        case server
        case confirm
        case pair
        case done
    }

    @StateObject private var discovery = LocalServerDiscovery()
    @StateObject private var enrolment = BoomioEnrolment()
    @State private var dnsLookup = OverlayDNSTXT()

    @State private var step: Step = .server
    @State private var serverInput = ""
    @State private var plane: BoomioPlane?
    @State private var serverName = "Apple TV"
    @State private var inputError: String?
    @State private var advertNote: String?

    @State private var discovered: DiscoveredServer?
    @State private var checking = false
    @State private var trustServer = false

    var body: some View {
        ZStack {
            Color.tvBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                header
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 64)
        }
        .onAppear {
            if serverInput.isEmpty, AuthConfig.isConfigured {
                serverInput = AuthConfig.apiBaseURL
            }
            // A TV that already has a server must not be shown every
            // advertiser on the network by default. The rule lives in
            // `OverlayAdvert.matches(configuredHost:)`; this is what arms it.
            if AuthConfig.isConfigured, let host = URL(string: AuthConfig.apiBaseURL)?.host {
                discovery.configuredHost = host
            }
            discovery.start()
        }
        .onDisappear {
            discovery.stop()
            dnsLookup.cancel()
            enrolment.cancel()
        }
        .onChange(of: enrolment.stage) { _, stage in
            if case .ready = stage { step = .done }
        }
        .onExitCommand(perform: back)
    }

    private func back() {
        switch step {
        case .server:
            onClose()
        case .confirm:
            step = .server
        case .pair:
            enrolment.cancel()
            step = .server
        case .done:
            onClose()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("boomio_setup_title", fallback: "Set up this Apple TV"))
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(.white)
            Text(L10n.string(
                "boomio_setup_subtitle",
                fallback: "Pair this TV with your Boomio box, register its certificate and enrol its tunnel key."
            ))
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .server:
            serverStep
        case .confirm:
            confirmStep
        case .pair:
            pairStep
        case .done:
            doneStep
        }
    }

    // MARK: - Step 1: which box

    private var serverStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string(
                    "boomio_setup_server_help",
                    fallback: "Pick the box on your network, or enter its address. One address is all that is needed — the app derives the pairing, certificate and media endpoints from it."
                ))
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)

                if AuthConfig.isConfigured {
                    LoginButton(
                        title: L10n.format(
                            "boomio_setup_current_server",
                            fallback: "Use %@",
                            Self.hostLabel(AuthConfig.apiBaseURL)
                        ),
                        systemImage: "checkmark.seal"
                    ) {
                        begin(urlString: AuthConfig.apiBaseURL, preTrusted: true)
                    }
                }

                if !discovery.boxes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.string("auth_discovered_boxes", fallback: "Found on your network"))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                        ForEach(discovery.boxes) { box in
                            VStack(alignment: .leading, spacing: 6) {
                                LoginButton(title: box.name, systemImage: "appletv") {
                                    begin(urlString: box.backendURL)
                                }
                                Text(box.detail)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.45))
                            }
                        }
                    }
                }

                if let conflict = discovery.conflictMessage {
                    Text(conflict)
                        .font(.system(size: 17))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure = discovery.failureMessage {
                    Text(failure)
                        .font(.system(size: 16))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Only offered when the configured host is filtering the list:
                // a TV that already has a box sees that box, and the user can
                // deliberately widen the search.
                if discovery.configuredHost != nil {
                    LoginLinkButton(title: L10n.string(
                        "boomio_setup_show_all",
                        fallback: "Show every box on this network"
                    )) {
                        discovery.configuredHost = nil
                        discovery.restart()
                    }
                }

                LoginGlassField(
                    placeholder: L10n.string("auth_backend_url", fallback: "Box address (https://…)"),
                    text: $serverInput,
                    keyboardType: .URL
                )
                    .onChange(of: serverInput) { _, _ in inputError = nil }

                if let inputError {
                    Text(inputError)
                        .font(.system(size: 16))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LoginButton(
                    title: checking
                        ? L10n.string("auth_checking_server", fallback: "Checking Server…")
                        : L10n.string("boomio_setup_continue", fallback: "Check This Address"),
                    systemImage: "checkmark.shield",
                    prominent: true,
                    disabled: checking || serverInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    begin(urlString: serverInput)
                }

                if discovery.isSearching {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.string("auth_searching_boxes", fallback: "Looking for a Boomio box on your network…"))
                            .font(.system(size: 17))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                if !discovery.diagnostics.isEmpty {
                    Text(discovery.diagnostics)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }

                LoginButton(
                    title: L10n.string("auth_search_again", fallback: "Search Again"),
                    systemImage: "arrow.clockwise"
                ) {
                    discovery.restart()
                }
            }
        }
    }

    // MARK: - Step 2: confirm the server is the one meant

    @ViewBuilder
    private var confirmStep: some View {
        if let discovered {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string(
                    "boomio_setup_confirm_help",
                    fallback: "This address answered as a Boomio server. Pairing sends this TV's identity to it, so confirm it is yours."
                ))
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)

                Text(discovered.configuration.backendURL)
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundColor(.white)

                let methods = [
                    discovered.configuration.capabilities.emailPasswordAuth
                        ? L10n.string("auth_method_email", fallback: "Email")
                        : nil,
                    discovered.configuration.capabilities.tvLogin
                        ? L10n.string("auth_method_qr", fallback: "QR")
                        : nil,
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                Text(L10n.format("auth_sign_in_methods", fallback: "Sign-in: %@", methods))
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.7))

                ForEach(discovered.securityWarnings, id: \.self) { warning in
                    Text(warning)
                        .font(.system(size: 16))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(
                    L10n.string("auth_trust_server", fallback: "I trust this server"),
                    isOn: $trustServer
                )
                    .foregroundColor(.white)

                LoginButton(
                    title: L10n.string("boomio_setup_pair", fallback: "Pair this Apple TV"),
                    systemImage: "link",
                    prominent: true,
                    disabled: !trustServer
                ) {
                    pair(with: discovered)
                }

                LoginButton(
                    title: L10n.string("action_back", fallback: "Back"),
                    systemImage: "chevron.left"
                ) {
                    step = .server
                }
                }
            }
        } else {
            busy(L10n.string("auth_checking_server", fallback: "Checking Server…"))
        }
    }

    // MARK: - Step 3: approve on the phone

    @ViewBuilder
    private var pairStep: some View {
        switch enrolment.stage {
        case .pairing(let userCode, let verificationURI):
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L10n.string(
                        "boomio_setup_pair_help",
                        fallback: "Enter this code in your phone's Boomio app, or open the address below on any device that is signed in."
                    ))
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    if let advertNote {
                        Text(advertNote)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(userCode)
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .foregroundColor(.white)

                    // Directly under the code, and therefore the first focusable
                    // control: with the QR below it this used to be pushed past
                    // the bottom of the screen on a real TV, and the remote had
                    // nothing to move down to. The Menu button is the same exit
                    // (onExitCommand), but a visible control must be reachable.
                    LoginButton(
                        title: L10n.string("action_cancel", fallback: "Cancel"),
                        systemImage: "xmark"
                    ) {
                        enrolment.cancel()
                        step = .server
                    }

                    HStack(alignment: .top, spacing: 28) {
                        if let image = QRCode.image(from: verificationURI.absoluteString, scale: 10) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 180, height: 180)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Text(verificationURI.absoluteString)
                                .font(.system(size: 18, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(2)
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(L10n.string("boomio_setup_waiting", fallback: "Waiting for approval…"))
                                    .font(.system(size: 18))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                }
            }
        case .registering:
            busy(L10n.string(
                "boomio_setup_registering",
                fallback: "Approved. Registering this TV's certificate with the box…"
            ))
        case .enrolling:
            busy(L10n.string(
                "boomio_setup_enrolling",
                fallback: "Certificate registered. Enrolling the tunnel key…"
            ))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string("boomio_setup_failed", fallback: "Setup did not finish"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 19))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let plane {
                    // A held session makes this the cheap retry: the same
                    // certificate and key are re-sent, no new code. Without
                    // one it starts over at pairing.
                    LoginButton(
                        title: L10n.string("action_retry", fallback: "Try Again"),
                        systemImage: "arrow.clockwise",
                        prominent: true
                    ) {
                        enrolment.start(plane: plane, serverName: serverName)
                        step = .pair
                    }
                }
                LoginButton(title: L10n.string("action_back", fallback: "Back"), systemImage: "chevron.left") {
                    step = .server
                }
            }
        case .idle, .ready:
            busy(L10n.string("boomio_setup_preparing", fallback: "Preparing…"))
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 16) {
            ProgressView()
            Text(text)
                .font(.system(size: 21))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 20)
    }

    // MARK: - Step 4: what the box now knows

    private var doneStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(L10n.string("boomio_setup_done", fallback: "This Apple TV is paired"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(Color(red: 0.49, green: 1.0, blue: 0.61))

                detailRow(
                    L10n.string("boomio_setup_certificate", fallback: "Client certificate"),
                    value: enrolment.certificateFingerprint.map(Self.groupedFingerprint) ?? "—"
                )

                detailRow(
                    L10n.string("boomio_setup_device_key", fallback: "Tunnel public key"),
                    value: enrolment.devicePublicKey ?? "—"
                )

                detailRow(
                    L10n.string("boomio_setup_tunnel", fallback: "Tunnel address"),
                    value: enrolment.tunnelAddress ?? "not assigned"
                )

                Text(L10n.string(
                    "boomio_setup_tunnel_note",
                    fallback: "The tunnel key is enrolled with the box so this TV is a known device. Apple TV has no VPN entitlement, so the tunnel itself is not used — local network access is."
                ))
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if let serverPublicKey = enrolment.serverPublicKey {
                    detailRow(
                        L10n.string("boomio_setup_server_key", fallback: "Server key"),
                        value: serverPublicKey
                    )
                }

                // The box can lose a certificate (a reset, a new edge). This
                // re-sends the SAME certificate under the session the TV
                // already holds, which is the repair the allow-list needs.
                LoginLinkButton(title: L10n.string(
                    "boomio_setup_reregister",
                    fallback: "Re-register Certificate"
                )) {
                    Task { await enrolment.reregisterCertificate() }
                }

                LoginButton(
                    title: L10n.string("action_done", fallback: "Done"),
                    systemImage: "checkmark",
                    prominent: true
                ) {
                    onClose()
                }
            }
            .padding(.top, 8)
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    /// Validates an address with the app's own discovery document, then asks
    /// the user to confirm it before anything is sent to it.
    private func begin(urlString: String, preTrusted: Bool = false) {
        inputError = nil
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url: URL
        do {
            url = try ServerDiscoveryPolicy.normalizeInput(trimmed)
        } catch {
            // normalizeInput's message names the problem (missing scheme,
            // unsupported scheme) — repeat it rather than inventing one.
            inputError = error.localizedDescription
            return
        }

        // The pairing calls carry a bearer and the certificate is worthless
        // without TLS, so http is refused here rather than warned about.
        guard url.scheme?.lowercased() == "https" else {
            inputError = L10n.string(
                "boomio_setup_https_only",
                fallback: "Use https:// — pairing sends a session token and this TV's certificate."
            )
            return
        }

        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                let found = try await ServerDiscoveryService().discover(input: trimmed)
                discovered = found
                trustServer = preTrusted
                step = .confirm
            } catch {
                inputError = error.localizedDescription
            }
        }
    }

    private func pair(with discovered: DiscoveredServer) {
        guard let url = URL(string: discovered.configuration.backendURL),
              let plane = BoomioPlane(backendURL: url)
        else {
            inputError = L10n.string("boomio_setup_bad_address", fallback: "That address has no host to connect to.")
            step = .server
            return
        }

        self.plane = plane
        serverName = plane.serviceOrigin.host.map { "Apple TV (\($0))" } ?? "Apple TV"
        lookupAdvert(for: plane)
        step = .pair
        enrolment.start(plane: plane, serverName: serverName)
    }

    /// Cross-checks the address against the box's DNS TXT tuple.
    ///
    /// Informational only: a missing record is normal on a LAN-only box, and a
    /// mismatched one is not proof of anything — the certificate presented on
    /// TLS is the real check. But a record that names a DIFFERENT `svc` than
    /// the address the user typed is the signature of a stale or spoofed
    /// record, and worth showing before they approve a code on their phone.
    private func lookupAdvert(for plane: BoomioPlane) {
        advertNote = nil
        guard let host = plane.serviceOrigin.host,
              !Self.isIPv4Literal(host)
        else { return }

        dnsLookup.lookup(host: host) { advert in
            guard let advert else {
                self.advertNote = L10n.string(
                    "boomio_setup_no_txt",
                    fallback: "No DNS advert for this address — pairing uses the address you entered."
                )
                return
            }
            let advertisedHost = URL(string: "https://" + advert.serviceName)?.host?.lowercased()
            if let advertisedHost, advertisedHost != host.lowercased() {
                self.advertNote = L10n.format(
                    "boomio_setup_txt_mismatch",
                    fallback: "⚠︎ The DNS advert names %@, not %@. Check the address before approving.",
                    advert.serviceName,
                    host
                )
            } else {
                let lan = advert.lanHost ?? "—"
                self.advertNote = "DNS advert: v2 · svc \(advert.serviceName) · lan \(lan)"
            }
        }
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        host.range(of: #"^[0-9]{1,3}(\.[0-9]{1,3}){3}$"#, options: .regularExpression) != nil
    }

    private static func hostLabel(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    /// `a1b2c3d4 e5f6…`, eight hex characters to a group, four groups a line —
    /// long enough to compare against the box, short enough to read across a
    /// living room.
    private static func groupedFingerprint(_ fingerprint: String) -> String {
        var groups: [String] = []
        var index = fingerprint.startIndex
        while index < fingerprint.endIndex {
            let next = fingerprint.index(index, offsetBy: 8, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
            groups.append(String(fingerprint[index..<next]))
            index = next
        }
        var lines: [String] = []
        for start in stride(from: 0, to: groups.count, by: 4) {
            lines.append(groups[start..<min(start + 4, groups.count)].joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
