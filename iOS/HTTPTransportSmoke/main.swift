import Foundation

@main
struct HTTPTransportSmoke {
    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let pin = try String(contentsOf: fixture.appendingPathComponent("certificate-sha256.txt"), encoding: .utf8)
        let transport = WiredHTTPTransport(policy: .remoteDirect, certificateSHA256: pin)
        let expected = Data("{\"hung_up\":true}".utf8)
        for path in ["complete", "fragmented", "chunked", "unframed", "no-content"] {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:18446/\(path)")!)
            request.timeoutInterval = 1.5
            let started = Date()
            let response = try await transport.send(request)
            precondition(Date().timeIntervalSince(started) < 1.5)
            precondition(response.statusCode == (path == "no-content" ? 204 : 200))
            precondition(response.body == (path == "no-content" ? Data() : expected))
        }
        for path in ["truncated", "chunked-incomplete"] {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:18446/\(path)")!)
            request.timeoutInterval = 1.5
            var rejected = false
            do { _ = try await transport.send(request) }
            catch { rejected = true }
            precondition(rejected, "Truncated response must not confirm hangup")
        }
        testClockSkew()
        testEarlyMedia()
        testPlaybackRecovery()
        print("PASS HTTP framing over TLS: complete, fragmented, chunked, trailers, EOF, truncation")
        print("PASS end confirmation across device clock skew, with stale identity/generation rejection")
        print("PASS outgoing early media without answering ringing calls or restarting ended calls")
        print("PASS playback recovery and waiting tone handoff to carrier audio")
    }

    static func testPlaybackRecovery() {
        precondition(LocalAudioPlaybackPolicy.shouldRecover(active: true, interrupted: false, engineRunning: false, playerPlaying: true))
        precondition(LocalAudioPlaybackPolicy.shouldRecover(active: true, interrupted: false, engineRunning: true, playerPlaying: false))
        precondition(!LocalAudioPlaybackPolicy.shouldRecover(active: true, interrupted: false, engineRunning: true, playerPlaying: true))
        precondition(!LocalAudioPlaybackPolicy.shouldRecover(active: false, interrupted: false, engineRunning: false, playerPlaying: false))
        precondition(!LocalAudioPlaybackPolicy.shouldRecover(active: true, interrupted: true, engineRunning: false, playerPlaying: false))
        precondition(LocalAudioPlaybackPolicy.shouldPlayWaitingTone(state: "dialing", direction: "outgoing", receivedCarrierAudio: false))
        precondition(!LocalAudioPlaybackPolicy.shouldPlayWaitingTone(state: "dialing", direction: "outgoing", receivedCarrierAudio: true))
        precondition(!LocalAudioPlaybackPolicy.shouldPlayWaitingTone(state: "active", direction: "outgoing", receivedCarrierAudio: false))
        precondition(!LocalAudioPlaybackPolicy.shouldPlayWaitingTone(state: "incoming", direction: "incoming", receivedCarrierAudio: false))
        precondition(!LocalAudioPlaybackPolicy.shouldPlayWaitingTone(state: "ended", direction: "outgoing", receivedCarrierAudio: false))
    }

    static func testEarlyMedia() {
        for state in ["dialing", "alerting", "connecting"] {
            precondition(LocalCallMediaStartupPolicy.shouldStart(state: state, direction: "outgoing", lifecycle: .connecting))
            precondition(!LocalCallMediaStartupPolicy.shouldStart(state: state, direction: "incoming", lifecycle: .connecting))
        }
        precondition(LocalCallMediaStartupPolicy.shouldStart(state: "active", direction: "incoming", lifecycle: .active))
        precondition(!LocalCallMediaStartupPolicy.shouldStart(state: "incoming", direction: "incoming", lifecycle: .ringing))
        for lifecycle: CallLifecycleState in [.idle, .ending, .ended, .failed] {
            precondition(!LocalCallMediaStartupPolicy.shouldStart(state: "dialing", direction: "outgoing", lifecycle: lifecycle))
            precondition(!LocalCallMediaStartupPolicy.shouldStart(state: "active", direction: "outgoing", lifecycle: lifecycle))
        }
    }

    static func testClockSkew() {
        let id = UUID()
        func event(_ state: CallLifecycleState, _ source: CallLifecycleSource,
                   _ seconds: TimeInterval, callID: String = "call-1",
                   uuid: UUID? = nil, generation: UInt64 = 2) -> CallLifecycleEvent {
            CallLifecycleEvent(callID: callID, callUUID: uuid ?? id, generation: generation,
                               state: state, source: source, timestamp: Date(timeIntervalSince1970: seconds),
                               traceID: nil, failure: nil)
        }
        var store = CallLifecycleStore()
        precondition(store.apply(event(.active, .agent, 100)))
        precondition(!store.apply(event(.active, .agent, 90)))
        precondition(store.apply(event(.ending, .app, 110)))
        precondition(!store.apply(event(.ended, .agent, 105, callID: "wrong-call")))
        precondition(!store.apply(event(.ended, .agent, 105, uuid: UUID())))
        precondition(!store.apply(event(.ended, .agent, 105, generation: 1)))
        precondition(!store.apply(event(.ended, .app, 105)))
        precondition(store.apply(event(.ended, .agent, 105)))
        precondition(store.snapshot.state == .ended)
        precondition(!store.apply(event(.active, .agent, 200)))
    }
}
