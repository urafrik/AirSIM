import Foundation
import Network
import Security
import CryptoKit

/// Exact leaf-certificate pinning, shared by iPhone control/audio and Watch audio.
/// A nil pin preserves platform CA validation. An invalid/mismatched pin never falls back.
enum PinnedTLS {
    static func normalize(_ value: String) -> String? {
        let hex = value.filter { !$0.isWhitespace && $0 != ":" }.lowercased()
        guard hex.count == 64, hex.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return hex
    }

    static func options(host: String, certificateSHA256: String?) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
        guard let expected = certificateSHA256 else { return options }
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            complete(verify(value, host: host, certificateSHA256: expected))
        }, DispatchQueue(label: "airsim.certificate-pin"))
        return options
    }

    static func verify(_ trust: SecTrust, host: String, certificateSHA256: String) -> Bool {
        guard let expected = normalize(certificateSHA256),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return false }
        let actual = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        // Compare every byte. The pin is public, but avoid a data-dependent early return.
        let mismatch = zip(actual.utf8, expected.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard mismatch == 0,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        // Trust only the pinned leaf, retaining SSL hostname, usage and validity checks.
        return SecTrustEvaluateWithError(trust, nil)
    }
}
