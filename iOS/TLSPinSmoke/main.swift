import Foundation
import Network
import Security

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let pin = try String(contentsOf: fixture.appendingPathComponent("certificate-sha256.txt"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let der = try Data(contentsOf: fixture.appendingPathComponent("server.der"))
let certificate = SecCertificateCreateWithData(nil, der as CFData)!

func trust(host: String, date: Date? = nil) -> SecTrust {
    var value: SecTrust?
    check(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &value) == errSecSuccess,
          "Could not create test trust")
    if let date { check(SecTrustSetVerifyDate(value!, date as CFDate) == errSecSuccess, "Could not set test date") }
    return value!
}

check(PinnedTLS.normalize(pin.uppercased()) == pin, "Uppercase pin normalization")
let colonPin = stride(from: 0, to: pin.count, by: 2).map { offset -> String in
    let start = pin.index(pin.startIndex, offsetBy: offset)
    return String(pin[start..<pin.index(start, offsetBy: 2)])
}.joined(separator: ":")
check(PinnedTLS.normalize(colonPin) == pin, "Colon pin normalization")
check(PinnedTLS.normalize("not-a-pin") == nil, "Malformed pin must be rejected")
check(PinnedTLS.verify(trust(host: "pin-test.example.test"), host: "pin-test.example.test", certificateSHA256: pin),
      "Correct self-signed leaf and hostname should be accepted")
check(!PinnedTLS.verify(trust(host: "wrong.example.test"), host: "wrong.example.test", certificateSHA256: pin),
      "Wrong hostname must be rejected")
check(!PinnedTLS.verify(trust(host: "pin-test.example.test"), host: "pin-test.example.test", certificateSHA256: String(repeating: "0", count: 64)),
      "Wrong certificate pin must be rejected")
check(!PinnedTLS.verify(trust(host: "pin-test.example.test", date: Date().addingTimeInterval(86400 * 730)),
                       host: "pin-test.example.test", certificateSHA256: pin), "Expired pinned leaf must be rejected")

let secret = Data(repeating: 0x42, count: 32).base64EncodedString()
let watch: [String: Any] = ["pcm_host": "pin-test.example.test", "pcm_port": 17593,
                          "pcm_secret": secret, "pcm_tls": true, "pcm_certificate_sha256": pin]
check(WatchLocalPCMEndpoint(dictionary: watch)?.certificateSHA256 == pin, "Watch must retain certificate pin")
var badWatch = watch
badWatch["pcm_certificate_sha256"] = "invalid"
check(WatchLocalPCMEndpoint(dictionary: badWatch) == nil, "Watch must reject invalid pin instead of downgrading")

let portFile = fixture.appendingPathComponent("port.txt")
for _ in 0..<100 where !FileManager.default.fileExists(atPath: portFile.path) { Thread.sleep(forTimeInterval: 0.05) }
let port = UInt16(try String(contentsOf: portFile, encoding: .utf8))!
func handshake(host: String, pin: String?) -> Bool {
    let done = DispatchSemaphore(value: 0)
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: PinnedTLS.options(host: host, certificateSHA256: pin), tcp: .init()))
    let lock = NSLock()
    var ready = false
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            lock.lock(); ready = true; lock.unlock()
            done.signal()
        case .failed: done.signal()
        default: break
        }
    }
    connection.start(queue: DispatchQueue(label: "pin-smoke-network"))
    _ = done.wait(timeout: .now() + 10)
    connection.cancel()
    lock.lock(); defer { lock.unlock() }
    return ready
}
check(handshake(host: "pin-test.example.test", pin: pin), "Real TLS handshake with pinned self-signed leaf failed")
check(!handshake(host: "pin-test.example.test", pin: String(repeating: "0", count: 64)), "Real TLS accepted wrong pin")
check(!handshake(host: "wrong.example.test", pin: pin), "Real TLS accepted wrong hostname")
check(!handshake(host: "pin-test.example.test", pin: nil), "Unpinned self-signed leaf must not use fallback trust")
print("PASS: pin format, identity, hostname, expiration, Watch propagation and real TLS accept/reject handshakes")
