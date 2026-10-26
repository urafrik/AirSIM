import Foundation

enum DirectConnectionMode: String, CaseIterable, Identifiable {
    case automatic
    case remoteOnly
    case lanOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动（局域网优先）"
        case .remoteOnly: return "仅公网直连"
        case .lanOnly: return "仅局域网"
        }
    }
}

enum DirectConnectionPolicy {
    static func candidates<Endpoint: Equatable>(mode: DirectConnectionMode, local: [Endpoint],
                                                remote: Endpoint?, locked: Endpoint? = nil) -> [Endpoint] {
        if let locked { return [locked] }
        let proposed: [Endpoint]
        switch mode {
        case .automatic: proposed = local + (remote.map { [$0] } ?? [])
        case .remoteOnly: proposed = remote.map { [$0] } ?? []
        case .lanOnly: proposed = local
        }
        return proposed.reduce(into: []) { result, item in
            if !result.contains(item) { result.append(item) }
        }
    }

    @MainActor
    static func firstVerified<Endpoint>(candidates: [Endpoint], isCurrent: () -> Bool,
                                        probe: (Endpoint) async throws -> Void) async throws -> Endpoint? {
        var failure: Error?
        for endpoint in candidates {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            do {
                try await probe(endpoint)
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                return endpoint
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        if let failure { throw failure }
        return nil
    }
}

enum CellularSignalDisplay {
    static func bars(dbm: Int?) -> Int {
        guard let dbm, (-160 ... -20).contains(dbm) else { return 0 }
        if dbm >= -79 { return 4 }
        if dbm >= -89 { return 3 }
        if dbm >= -99 { return 2 }
        if dbm >= -109 { return 1 }
        return 0
    }
}
