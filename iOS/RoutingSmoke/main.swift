import Foundation

@main
struct RoutingSmoke {
    @MainActor
    static func main() async throws {
        let candidates = DirectConnectionPolicy.candidates(mode: .automatic, local: ["lan", "lan"], remote: "public")
        precondition(candidates == ["lan", "public"])
        precondition(DirectConnectionPolicy.candidates(mode: .automatic, local: [String](), remote: "public") == ["public"])
        precondition(DirectConnectionPolicy.candidates(mode: .remoteOnly, local: ["lan"], remote: "public") == ["public"])
        precondition(DirectConnectionPolicy.candidates(mode: .lanOnly, local: ["lan"], remote: "public") == ["lan"])
        precondition(DirectConnectionPolicy.candidates(mode: .automatic, local: ["new-lan"], remote: "public", locked: "call-lan") == ["call-lan"])

        var visited: [String] = []
        let fallback = try await DirectConnectionPolicy.firstVerified(candidates: candidates, isCurrent: { true }) { endpoint in
            visited.append(endpoint)
            if endpoint == "lan" { throw URLError(.notConnectedToInternet) }
        }
        precondition(fallback == "public" && visited == ["lan", "public"])
        visited = []
        let returned = try await DirectConnectionPolicy.firstVerified(candidates: candidates, isCurrent: { true }) { visited.append($0) }
        precondition(returned == "lan" && visited == ["lan"])

        var epoch = 1
        var rejectedStale = false
        do {
            _ = try await DirectConnectionPolicy.firstVerified(candidates: ["old-network"], isCurrent: { epoch == 1 }) { _ in epoch = 2 }
        } catch is CancellationError { rejectedStale = true }
        precondition(rejectedStale)

        let name = "AirSIMRoutingSmoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        precondition(ManualDirectConfiguration.endpoint(defaults: defaults) == nil)
        try ManualDirectConfiguration.save(host: "example.com", control: "17592", pcm: "17593", defaults: defaults)
        let saved = ManualDirectConfiguration.endpoint(defaults: defaults)
        precondition(saved != nil)
        defaults.removeObject(forKey: ManualDirectConfiguration.modeKey)
        defaults.set(false, forKey: ManualDirectConfiguration.enabledKey)
        precondition(ManualDirectConfiguration.endpoint(defaults: defaults) == saved, "Old LAN-only switch must not discard a saved public fallback")
        ManualDirectConfiguration.setMode(.lanOnly, defaults: defaults)
        precondition(ManualDirectConfiguration.endpoint(defaults: defaults) == nil)
        precondition(ManualDirectConfiguration.savedEndpoint(defaults: defaults) == saved)
        ManualDirectConfiguration.setMode(.automatic, defaults: defaults)
        precondition(ManualDirectConfiguration.endpoint(defaults: defaults) == saved)
        do {
            try ManualDirectConfiguration.save(host: "invalid/path", control: "17592", pcm: "17593", defaults: defaults)
            preconditionFailure("Invalid endpoint accepted")
        } catch {}
        precondition(ManualDirectConfiguration.endpoint(defaults: defaults) == saved)
        precondition(CellularSignalDisplay.bars(dbm: -75) == 4)
        precondition(CellularSignalDisplay.bars(dbm: -95) == 2)
        precondition(CellularSignalDisplay.bars(dbm: -105) == 1)
        precondition(CellularSignalDisplay.bars(dbm: nil) == 0)
        precondition(CellularSignalDisplay.bars(dbm: 0) == 0)
        precondition(CellularSignalDisplay.bars(dbm: Int.max) == 0)
        print("PASS automatic LAN/public failover, LAN return, call route lock, stale probe rejection, saved endpoint migration and signal bars")
    }
}
