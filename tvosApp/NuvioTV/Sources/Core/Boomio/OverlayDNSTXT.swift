//
//  OverlayDNSTXT.swift
//  NuvioTV
//
//  Boomio: read the advert over plain DNS when mDNS is unavailable.
//
//  The box publishes ONE tuple twice: avahi repeats it over mDNS, and
//  overlay-duckdns.py writes it as the TXT record of the box's own DuckDNS
//  name (the same name the certificate is issued for). That makes the typed
//  address self-describing: a client that already knows the host can ask DNS
//  for the LAN address, the ports and the tunnel public keys without any
//  multicast at all — and on networks that filter mDNS, this is the only
//  discovery that works.
//
//  It is not a trust path. The record is unsigned and spoofable exactly like
//  the mDNS one; `svc` is only checked for agreement with the address the user
//  typed, and the certificate presented on the next TLS connection is what
//  actually authenticates the box.
//
//  All state lives on ONE serial queue, and the reply is consumed inline on
//  that same queue (the DNSServiceRef's read source is scheduled there). That
//  is load-bearing: `DNSServiceProcessResult` invokes the C callback
//  synchronously, so a reply can never be handled after the query it belongs
//  to has been torn down, and the generation captured when the source was
//  installed is still the right one when the reply is delivered.
//

import Foundation
import dnssd

final class OverlayDNSTXT {
    private let queue = DispatchQueue(label: "com.nuvio.tv.boomio.dnstxt")
    private var service: DNSServiceRef?
    private var source: DispatchSourceRead?
    private var completion: ((OverlayAdvert?) -> Void)?
    private var generation = 0
    private var delivered = false

    /// Set by the C callback during `DNSServiceProcessResult`, consumed by the
    /// event handler immediately after it returns. Keeping these apart is what
    /// lets the service be deallocated OUTSIDE the DNS API call that is using
    /// it.
    private var replyReady = false
    private var replyAdvert: OverlayAdvert?

    deinit {
        // Never leave the C library holding a pointer to a freed object.
        source?.cancel()
        if let service { DNSServiceRefDeallocate(service) }
    }

    /// Queries the TXT record of `host`. The completion runs on the main
    /// queue, exactly once, with nil for "no record, timeout, or unparseable".
    func lookup(host: String, timeout: TimeInterval = 5, completion: @escaping (OverlayAdvert?) -> Void) {
        queue.async {
            self.teardown()
            self.generation += 1
            let generation = self.generation
            self.delivered = false
            self.replyReady = false
            self.replyAdvert = nil
            self.completion = completion

            var ref: DNSServiceRef?
            let error = DNSServiceQueryRecord(
                &ref,
                0,                      // no flags: one query, no follow-ups
                0,                      // all interfaces
                host,
                UInt16(kDNSServiceType_TXT),
                UInt16(kDNSServiceClass_IN),
                overlayDNSTXTReply,
                Unmanaged.passUnretained(self).toOpaque()
            )
            guard error == kDNSServiceErr_NoError, let ref else {
                self.settle(generation: generation, advert: nil)
                return
            }

            self.service = ref
            let fd = DNSServiceRefSockFD(ref)
            guard fd >= 0 else {
                self.settle(generation: generation, advert: nil)
                return
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in
                guard let self, let service = self.service else { return }
                _ = DNSServiceProcessResult(service)
                // Synchronously set by the callback above, on this queue.
                let ready = self.replyReady
                let advert = self.replyAdvert
                self.replyReady = false
                self.replyAdvert = nil
                if ready {
                    self.settle(generation: generation, advert: advert)
                }
            }
            source.resume()
            self.source = source

            self.queue.asyncAfter(deadline: .now() + timeout) {
                self.settle(generation: generation, advert: nil)
            }
        }
    }

    func cancel() {
        queue.async {
            self.teardown()
            self.generation += 1
            self.completion = nil
            self.replyReady = false
            self.replyAdvert = nil
        }
    }

    // MARK: - Reply

    /// Called by `DNSServiceProcessResult`, i.e. on `queue`, while the service
    /// is still alive. It records the outcome and returns; the caller decides
    /// when to tear down.
    fileprivate func handle(error: DNSServiceErrorType, length: Int, bytes: UnsafeRawPointer?) {
        guard !replyReady else { return }
        if error == kDNSServiceErr_NoError, length > 0, let bytes {
            let data = Data(bytes: bytes, count: length)
            replyAdvert = OverlayAdvert.parse(txtStrings: Self.strings(from: data))
        } else {
            replyAdvert = nil
        }
        replyReady = true
    }

    /// Runs on `queue`. Ignores a reply or timeout that belongs to a replaced
    /// lookup.
    private func settle(generation: Int, advert: OverlayAdvert?) {
        guard generation == self.generation, !delivered else { return }
        delivered = true
        teardown()

        let completion = self.completion
        self.completion = nil
        guard let completion else { return }
        DispatchQueue.main.async { completion(advert) }
    }

    /// Runs on `queue`.
    private func teardown() {
        source?.cancel()
        source = nil
        if let service {
            DNSServiceRefDeallocate(service)
            self.service = nil
        }
    }

    // MARK: - Framing

    /// TXT rdata: a sequence of length-prefixed strings, the same framing as
    /// `NetService.txtRecordData()`.
    private static func strings(from data: Data) -> [String] {
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

/// C function pointer: no captures, so the instance arrives as the context.
private let overlayDNSTXTReply: DNSServiceQueryRecordReply = { _, _, _, error, _, _, _, rdlen, rdata, _, context in
    guard let context else { return }
    let lookup = Unmanaged<OverlayDNSTXT>.fromOpaque(context).takeUnretainedValue()
    lookup.handle(error: error, length: Int(rdlen), bytes: rdata)
}
