//
//  X509.swift
//  NuvioTV
//
//  Boomio: mint the self-signed client certificate the box will trust.
//
//  There is no API on tvOS that produces a self-signed certificate from a
//  Keychain key, so the DER is written here. The shape is not arbitrary — it
//  is the Android client's (`core/mtls/MtlsCertificate.kt`), which the server
//  and the edge already accept:
//
//      subject = issuer = CN=<server-derived device name>   (no SAN, no O, no OU)
//      notBefore = now - 1 day,  notAfter = now + 3650 days
//      serial = 16 random bytes with the top bits forced to 01
//      basicConstraints critical CA:FALSE
//      keyUsage critical digitalSignature
//      extendedKeyUsage clientAuth (non-critical)
//      signature sha256WithRSA (PKCS#1 v1.5), RSA-2048
//
//  The layout was checked against `openssl x509 -text` and against Node's
//  `X509Certificate` — the parser the box itself uses — before being written
//  here, so the encoding below is a transcription of bytes that already parse.
//
//  Nothing about the certificate is secret; the private key never leaves the
//  Keychain and is never exported.
//

import Foundation
import Security

enum X509 {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Base64 PEM of a DER certificate, wrapped at 64 columns.
    static func pem(der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<next]))
            index = next
        }
        return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n")
            + "\n-----END CERTIFICATE-----\n"
    }

    /// Builds and signs a self-signed certificate for `commonName`.
    ///
    /// - Parameter key: an RSA private key of at least 2048 bits, held in the
    ///   Keychain. Its public half is exported (PKCS#1) and wrapped in the
    ///   SubjectPublicKeyInfo the certificate standard requires.
    static func selfSigned(
        commonName: String,
        key: SecKey,
        notBefore: Date = Date().addingTimeInterval(-86_400),
        notAfter: Date = Date().addingTimeInterval(3_650 * 86_400)
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw Failure(message: "no public key for the signing key")
        }
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw Failure(message: "public key is not exportable: \(describe(error))")
        }

        let signatureAlgorithm = algorithmIdentifier()
        let name = distinguishedName(commonName: commonName)
        let tbs = sequence(
            tlv(0xA0, integer(raw: Data([0x02]))),      // version: v3
            integer(raw: randomSerial()),
            signatureAlgorithm,
            name,
            sequence(utcTime(notBefore), utcTime(notAfter)),
            name,
            subjectPublicKeyInfo(pkcs1: pkcs1),
            tlv(0xA3, sequence(          // [3] EXPLICIT extensions
                basicConstraints(),
                keyUsage(),
                extendedKeyUsage()
            ))
        )

        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error
        ) as Data? else {
            throw Failure(message: "signing failed: \(describe(error))")
        }

        return sequence(tbs, signatureAlgorithm, bitString(signature))
    }

    // MARK: - Structure

    private static func algorithmIdentifier() -> Data {
        // sha256WithRSAEncryption (1.2.840.113549.1.1.11) with NULL parameters.
        sequence(oid("1.2.840.113549.1.1.11"), tlv(0x05, Data()))
    }

    private static func distinguishedName(commonName: String) -> Data {
        sequence(tlv(0x31, sequence(oid("2.5.4.3"), utf8String(commonName))))
    }

    private static func subjectPublicKeyInfo(pkcs1: Data) -> Data {
        // rsaEncryption (1.2.840.113549.1.1.1) + NULL, then the key bits.
        sequence(sequence(oid("1.2.840.113549.1.1.1"), tlv(0x05, Data())), bitString(pkcs1))
    }

    private static func basicConstraints() -> Data {
        // CA:FALSE is the DEFAULT for the extension, but Android writes it
        // explicitly and marks it critical; matching keeps the two clients'
        // certificates indistinguishable in the box's cert index.
        //
        // ⚠️ The inner BOOLEAN is the cA value — `false`. Writing `true` here
        // (with the first `boolean(...)` being the critical flag) mints a CA
        // certificate from a device key, which is authority the client must
        // not assert. The box does not check it today; that is not a reason to
        // emit it.
        sequence(oid("2.5.29.19"), boolean(true), octetString(sequence(boolean(false))))
    }

    private static func keyUsage() -> Data {
        // digitalSignature is bit 0 of the BIT STRING; both Android and this
        // writer emit the single-byte form with the unused-bit count.
        sequence(oid("2.5.29.15"), boolean(true), octetString(bitString(Data([0x80]))))
    }

    private static func extendedKeyUsage() -> Data {
        // clientAuth (1.3.6.1.5.5.7.3.2), non-critical.
        sequence(oid("2.5.29.37"), octetString(sequence(oid("1.3.6.1.5.5.7.3.2"))))
    }

    // MARK: - DER primitives

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func sequence(_ items: Data...) -> Data { sequence(items) }

    private static func sequence(_ items: [Data]) -> Data {
        tlv(0x30, items.reduce(Data(), +))
    }

    private static func integer(raw: Data) -> Data {
        var bytes = raw
        while bytes.count > 1 && bytes.first == 0x00 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return tlv(0x02, bytes)
    }

    private static func boolean(_ value: Bool) -> Data {
        tlv(0x01, Data([value ? 0xFF : 0x00]))
    }

    private static func bitString(_ payload: Data) -> Data {
        // Zero unused bits, then the payload.
        tlv(0x03, Data([0x00]) + payload)
    }

    private static func octetString(_ payload: Data) -> Data {
        tlv(0x04, payload)
    }

    private static func utf8String(_ text: String) -> Data {
        tlv(0x0C, Data(text.utf8))
    }

    private static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }

    private static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return tlv(0x06, Data()) }
        var out = Data([UInt8(40 * parts[0] + parts[1])])
        for part in parts.dropFirst(2) {
            var value = part
            var chunk: [UInt8] = []
            repeat {
                chunk.insert(UInt8(value & 0x7F), at: 0)
                value >>= 7
            } while value > 0
            for index in chunk.indices {
                out.append(index == chunk.count - 1 ? chunk[index] : chunk[index] | 0x80)
            }
        }
        return tlv(0x06, out)
    }

    private static func randomSerial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return Data([0x40] + Array(repeating: UInt8(0x01), count: 15))
        }
        // Top two bits `01`: positive, and fixed-width like Android's serial.
        bytes[0] = (bytes[0] & 0x3F) | 0x40
        return Data(bytes)
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else { return "unknown error" }
        return (error as Error).localizedDescription
    }
}
