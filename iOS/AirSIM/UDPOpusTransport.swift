import Foundation
import Network
import CryptoKit
import Security

protocol CallPCMTransport: AnyObject {
    func start()
    func stop()
    func sendPCM(_ pcm: Data)
}

enum UDPOpusConfiguration {
    static let enabledKey = "airsim.udp-opus.enabled"
    static let hostKey = "airsim.udp-opus.host"
    static let portKey = "airsim.udp-opus.port"
    static let service = "com.example.airsim.udp-opus"
    static func loadKey() -> Data? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "gateway-v1",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    static func save(host: String, port: String, key: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoWLANEndpoint.isValidManualHost(host), let port = UInt16(port), port > 0,
              hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw NSError(domain: "UDP", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写有效地址、端口和 64 位十六进制密钥"])
        }
        let chars = Array(hex)
        let data = Data(stride(from: 0, to: 64, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "gateway-v1"]
        var values = query
        values[kSecValueData as String] = data
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else { status = SecItemAdd(values as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        UserDefaults.standard.set(host, forKey: hostKey)
        UserDefaults.standard.set(Int(port), forKey: portKey)
    }
}

/// Experimental media only. Existing TLS control and Android HMAC handshake remain in use.
final class UDPOpusTransport: CallPCMTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "airsim.udp-opus", qos: .userInteractive)
    private let handshake: PCMHandshakeSequence
    private let onPCM: @Sendable (Data) -> Void
    private let onEvent: @Sendable (NetworkPCMTransport.Event) -> Void
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var codec: UnsafeMutableRawPointer?
    private var txKey: SymmetricKey?
    private var rxKey: SymmetricKey?
    private var sid = Data()
    private var sequence: UInt64 = 0
    private var highest: UInt64?
    private var seen = Set<UInt64>()
    private var ready = false
    private var stopped = false
    private var closing = false
    private var startedAt: TimeInterval = 0
    private var lastReceived: TimeInterval = 0
    private var lastHello: TimeInterval = 0
    private var lastStats: TimeInterval = 0
    private var hello = Data()
    private var sending = 0
    private var txIndex: UInt32 = 0
    private var jitter = UDPOpusJitterBuffer()
    private let captureLock = NSLock()
    private var captured = Data()
    private var upBytes: UInt64 = 0
    private var downBytes: UInt64 = 0
    private var upPeak = 0
    private var downPeak = 0
    private var concealed = 0
    private var captureDrops = 0
    private var lastTick: TimeInterval = 0

    init(handshake: PCMHandshakeSequence, onPCM: @escaping @Sendable (Data) -> Void,
         onEvent: @escaping @Sendable (NetworkPCMTransport.Event) -> Void) {
        self.handshake = handshake; self.onPCM = onPCM; self.onEvent = onEvent
    }

    func start() { queue.async { [self] in
        do {
            guard let key = UDPOpusConfiguration.loadKey(), key.count == 32,
                  let host = UserDefaults.standard.string(forKey: UDPOpusConfiguration.hostKey),
                  let port = UInt16(exactly: UserDefaults.standard.integer(forKey: UDPOpusConfiguration.portKey)),
                  port > 0 else { throw self.error("请先保存 UDP 网关地址、端口和密钥") }
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw self.error("随机数生成失败") }
            sid = Data(bytes)
            let psk = SymmetricKey(data: key)
            txKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: psk, salt: sid, info: Data("AirSIM-UDP-v1/client".utf8), outputByteCount: 32)
            rxKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: psk, salt: sid, info: Data("AirSIM-UDP-v1/server".utf8), outputByteCount: 32)
            guard let state = airsim_opus_create() else { throw self.error("Opus 初始化失败") }
            codec = state
            hello = Data([1]) + (try handshake.next())
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            connection = conn
            startedAt = ProcessInfo.processInfo.systemUptime
            lastReceived = startedAt
            conn.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped, !self.closing else { return }
                if case .ready = state { self.receive(); self.send(self.hello); self.lastHello = ProcessInfo.processInfo.systemUptime }
                if case let .failed(error) = state { self.fail(error.localizedDescription) }
            }
            conn.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
            onEvent(.status("UDP / Opus 测试：正在验证网关"))
        } catch { fail(error.localizedDescription) }
    } }

    func stop() { queue.async { [self] in
        if closing || stopped { return }
        if ready {
            for _ in 0..<3 { send(Data([6])) }
            ready = false; closing = true
            timer?.cancel(); timer = nil
            queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in cleanup() }
        } else { cleanup() }
    } }

    private func cleanup() {
        stopped = true; ready = false
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        if let codec { airsim_opus_destroy(codec) }; codec = nil
        captureLock.lock(); captured.removeAll(); captureLock.unlock()
        jitter = UDPOpusJitterBuffer()
    }
    private func fail(_ message: String) {
        guard !stopped else { return }
        cleanup(); onEvent(.failed("UDP 测试：\(message)。可关闭测试开关后重新通话，使用 TCP。"))
    }
    private func error(_ message: String) -> NSError { NSError(domain: "UDP", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    func sendPCM(_ pcm: Data) {
        captureLock.lock()
        captured.append(pcm)
        if captured.count > 320 * 8 {
            let excess = ((captured.count - 320 * 8 + 319) / 320) * 320
            captured.removeFirst(min(excess, captured.count)); captureDrops += excess / 320
        }
        captureLock.unlock()
    }

    private func send(_ payload: Data) {
        guard !stopped, let txKey, sequence < UInt64.max, (sending < 4 || payload.first == 6) else { return }
        do {
            let count = sequence; sequence += 1
            let header = Data("AUO1".utf8) + sid + Self.integer(count)
            let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + Self.integer(count))
            let box = try AES.GCM.seal(payload, using: txKey, nonce: nonce, authenticating: header)
            sending += 1
            connection?.send(content: header + box.ciphertext + box.tag, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async { self.sending = max(0, self.sending - 1); if let error { self.fail(error.localizedDescription) } }
            })
        } catch { fail("音频加密失败") }
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped, !self.closing else { return }
            if let data { self.consume(data) }
            if let error { self.fail(error.localizedDescription) } else { self.receive() }
        }
    }

    private func consume(_ packet: Data) {
        guard packet.count >= 45, packet.count <= 1200, packet.prefix(20) == Data("AUO1".utf8) + sid,
              let rxKey else { return }
        let seq = packet[20..<28].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard !seen.contains(seq), highest == nil || seq > highest! || highest! - seq < 64 else { return }
        do {
            let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + Data(packet[20..<28]))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: packet[28..<packet.count-16], tag: packet.suffix(16))
            let payload = try AES.GCM.open(box, using: rxKey, authenticating: packet.prefix(28))
            highest = max(highest ?? seq, seq); seen.insert(seq)
            seen = Set(seen.filter { highest! - $0 < 64 })
            lastReceived = ProcessInfo.processInfo.systemUptime
            guard let kind = payload.first else { return }
            if kind == 7 {
                fail("安卓音频会话已关闭，请查看电脑 gateway.log")
                return
            }
            if kind == 4 && !ready { ready = true; onEvent(.connected) }
            if kind == 3 && ready && payload.count > 5 && payload.count <= 405 {
                let index = payload[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                jitter.push(index, data: Data(payload.dropFirst(5)), now: lastReceived)
            }
        } catch { return }
    }

    private func tick() {
        guard !stopped, let codec else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReceived > 8 { fail("8 秒未收到网关响应，请检查 UDP 映射"); return }
        if !ready {
            if now - lastHello > 0.5 { send(hello); lastHello = now }
            captureLock.lock(); captured.removeAll(); captureLock.unlock()
            return
        }
        if lastTick > 0 && now - lastTick > 0.10 {
            jitter.rebuffer()
            captureLock.lock(); captured.removeAll(); captureLock.unlock()
        }
        lastTick = now
        captureLock.lock()
        let pcm = captured.count >= 320 ? Data(captured.prefix(320)) : nil
        if pcm != nil { captured.removeFirst(320) }
        let dropped = captureDrops
        captureLock.unlock()
        if let pcm {
            var samples = [Int16](repeating: 0, count: 160)
            for i in 0..<160 { samples[i] = Int16(bitPattern: UInt16(pcm[i*2]) | UInt16(pcm[i*2+1]) << 8) }
            var output = [UInt8](repeating: 0, count: 400)
            let length = airsim_opus_encode(codec, &samples, &output)
            if length > 0 {
                send(Data([2]) + Self.integer(txIndex) + Data(output.prefix(Int(length))))
                txIndex &+= 1; upBytes += 320; upPeak = max(upPeak, Self.peak(pcm))
            } else { fail("Opus 编码失败"); return }
        }
        if let item = jitter.pop(now: now) {
            let packet = item.packet
            let following = item.following
            let compressed = packet ?? following
            var samples = [Int16](repeating: 0, count: 160)
            let count: Int32
            if let compressed {
                count = compressed.withUnsafeBytes { raw in
                    airsim_opus_decode(codec, raw.bindMemory(to: UInt8.self).baseAddress, Int32(compressed.count), packet == nil ? 1 : 0, &samples)
                }
            } else { count = airsim_opus_decode(codec, nil, 0, 0, &samples) }
            if packet == nil { concealed += 1 }
            if count == 160 {
                let decoded = samples.withUnsafeBytes { Data($0) }
                downBytes += 320; downPeak = max(downPeak, Self.peak(decoded)); onPCM(decoded)
            }
        }
        if now - lastStats >= 1 {
            lastStats = now
            onEvent(.statistics(NetworkPCMStatistics(uplinkBytes: upBytes, uplinkPeak: upPeak,
                downlinkBytes: downBytes, downlinkPeak: downPeak,
                detail: " · UDP/Opus · 补偿\(concealed)帧 迟到\(jitter.late)帧 重对齐\(jitter.rebuffers)次 缓冲\(Int(jitter.delay * 1000))ms 上行丢旧\(dropped)帧")))
            send(Data([5]))
        }
    }
    private static func integer<T: FixedWidthInteger>(_ value: T) -> Data { var v = value.bigEndian; return withUnsafeBytes(of: &v) { Data($0) } }
    private static func peak(_ data: Data) -> Int {
        var peak = 0
        for i in stride(from: 0, to: data.count-1, by: 2) {
            peak = max(peak, abs(Int(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i+1]) << 8))))
        }
        return peak
    }
}
