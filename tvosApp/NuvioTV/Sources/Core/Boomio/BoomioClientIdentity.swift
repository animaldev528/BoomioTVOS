//
//  BoomioClientIdentity.swift
//  NuvioTV
//
//  Boomio: the TV's cryptographic identity towards one box.
//
//  Three things, all Keychain-backed and created once per install:
//
//    device id      stable `nuvio-tvos-<uuid>`; the box derives the certificate
//                   CN from it, so it must not change under the app's feet.
//    RSA-2048 key   non-exportable, used to self-sign the client certificate.
//    certificate    self-signed X.509 whose CN the server assigns (see
//                   BoomioDeviceName), registered with `/api/overlay/cert`.
//
//  ⚠️ The certificate must be REUSED, never re-minted. The edge compares the
//  presented leaf DER against the registered bytes, so a fresh certificate on
//  every launch silently drops the device out of the allow-list while every
//  upload still reports success. A new certificate is minted only when there
//  is none, or when the device id it was named for no longer matches.
//

import CryptoKit
import Foundation
import Security
import UIKit

struct BoomioClientCertificate {
    let commonName: String
    let der: Data
    let pem: String

    var fingerprintSHA256: String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

enum BoomioIdentityError: LocalizedError {
    case keychain(OSStatus)
    case keyCreation(Int32)
    case certificate(Int32)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "keychain error \(status)"
        case .keyCreation(let status):
            return "could not create the device key (status \(status))"
        case .certificate(let status):
            return "could not create the client certificate (status \(status))"
        case .unavailable(let reason):
            return reason
        }
    }
}

final class BoomioClientIdentity {
    static let shared = BoomioClientIdentity()

    private let service = "com.nuvio.tv.boomio"
    private let deviceIdAccount = "device.id"
    /// The CN the stored certificate was minted for.
    ///
    /// Kept beside the certificate rather than parsed back out of it:
    /// `SecCertificateCopySubjectSummary` is documented as a human-readable
    /// summary, not an accessor for CN, and a summary that is not exactly the
    /// CN would make every launch look like a CN mismatch and re-mint the
    /// certificate — the exact churn that silently drops a device out of the
    /// edge allow-list.
    private let certificateNameAccount = "cert.cn.v1"
    /// Fallback vendor identifier, persisted so it is stable when
    /// `identifierForVendor` is unavailable.
    private let hardwareIdAccount = "hw.uuid.v1"
    private let keyTag = Data("com.nuvio.tv.boomio.clientkey.v1".utf8)
    private let label = "Boomio Client"

    private(set) var deviceId: String
    private(set) var hardwareFingerprint: String

    init() {
        deviceId = Self.loadOrCreateDeviceId(service: service, account: deviceIdAccount)
        hardwareFingerprint = BoomioDeviceName.hardwareFingerprint(
            vendorIdentifier: Self.vendorIdentifier(account: hardwareIdAccount)
        )
    }

    /// The certificate this install registers, minting one only if needed.
    ///
    /// - Parameter forceNew: replace an existing certificate. This is the
    ///   operator's recovery path for a revoked device — it is never the
    ///   default, because re-minting is what breaks the edge allow-list.
    func certificate(forceNew: Bool = false) throws -> BoomioClientCertificate {
        let expectedName = BoomioDeviceName.peerName(forDeviceId: deviceId)

        if !forceNew, let stored = loadCertificate() {
            // A certificate named for a different device id can never be
            // registered: the server checks the CN against the session.
            let mintedFor = BoomioSecureStore.string(certificateNameAccount) ?? stored.commonName
            if mintedFor == expectedName { return stored }
            removeCertificate()
        } else if forceNew {
            removeCertificate()
        }

        let key = try loadOrCreateKey()
        let der: Data
        do {
            der = try X509.selfSigned(commonName: expectedName, key: key)
        } catch {
            // The DER writer's own message says WHY (public key not
            // exportable, signing refused); collapsing it to a status code
            // turns an actionable failure into a mystery on a TV with no logs.
            throw BoomioIdentityError.unavailable(
                "could not sign the client certificate: \(error.localizedDescription)"
            )
        }

        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw BoomioIdentityError.certificate(-2)
        }

        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary, nil)
        // errSecDuplicateItem is fine: the certificate is already there and
        // identical bytes are what the edge wants.
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw BoomioIdentityError.keychain(addStatus)
        }
        BoomioSecureStore.save(expectedName, account: certificateNameAccount)

        return BoomioClientCertificate(commonName: expectedName, der: der, pem: X509.pem(der: der))
    }

    /// The Keychain identity used to present the certificate on TLS.
    ///
    /// Returns nil when the pair cannot be formed — the caller then simply
    /// presents no certificate rather than failing the request, because the
    /// edge observes client certificates but does not yet require them.
    func secIdentity() -> SecIdentity? {
        var result: CFTypeRef?
        // An identity is matched by the private key's tag, not by the
        // certificate label: the label is on the certificate, and an identity
        // query is satisfied through its key.
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result else { return nil }
        // `as?` on a CoreFoundation type is refused by the compiler: the
        // conditional cast is statically known to succeed. The item was
        // matched as a kSecClassIdentity, so this is a checked coercion, not
        // a guess.
        return result as! SecIdentity
    }

    // MARK: - Keychain

    private func loadOrCreateKey() throws -> SecKey {
        if let existing = loadKey() { return existing }

        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                // Non-exportable is an INVARIANT here, not a hope: the key
                // signs the client certificate, and the default Keychain
                // policy would let anything in this process export it.
                kSecAttrIsExtractable as String: false,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw BoomioIdentityError.keyCreation(-1)
        }
        return key
    }

    private func loadKey() -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result else { return nil }
        return result as! SecKey
    }

    private func loadCertificate() -> BoomioClientCertificate? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result else { return nil }
        let certificate = result as! SecCertificate
        let der = SecCertificateCopyData(certificate) as Data
        guard let summary = SecCertificateCopySubjectSummary(certificate) else { return nil }
        return BoomioClientCertificate(commonName: summary as String, der: der, pem: X509.pem(der: der))
    }

    private func removeCertificate() {
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
        BoomioSecureStore.remove(certificateNameAccount)
    }

    // MARK: - Device id

    /// `identifierForVendor`, or a stored UUID when the system reports none.
    ///
    /// ⚠️ The fallback is PERSISTED. A fresh UUID per launch would change the
    /// hardware fingerprint every boot, which defeats the box's row-rejoin and
    /// makes one TV look like a new device each time it opens the app.
    private static func vendorIdentifier(account: String) -> UUID {
        if let current = UIDevice.current.identifierForVendor { return current }
        if let stored = BoomioSecureStore.string(account), let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let created = UUID()
        BoomioSecureStore.save(created.uuidString, account: account)
        return created
    }

    private static func loadOrCreateDeviceId(service: String, account: String) -> String {
        if let existing = readString(service: service, account: account) { return existing }
        let created = BoomioDeviceName.deviceIdPrefix + UUID().uuidString.lowercased()
        saveString(created, service: service, account: account)
        return created
    }

    private static func readString(service: String, account: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveString(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }
}
