import Foundation

/// A missing packet must never move the playout clock ahead forever.
struct UDPOpusJitterBuffer {
    private(set) var frames: [UInt32: Data] = [:]
    private(set) var next: UInt32?
    private var start: TimeInterval = 0
    private var highest: UInt32?
    private var misses = 0
    private var lateStreak = 0
    private(set) var delay: TimeInterval = 0.06
    private(set) var lost = 0
    private(set) var late = 0
    private(set) var rebuffers = 0

    mutating func rebuffer() {
        frames.removeAll(); next = nil; start = 0
        misses = 0; lateStreak = 0
        delay = min(0.12, delay + 0.02); rebuffers += 1
    }

    mutating func push(_ index: UInt32, data: Data, now: TimeInterval) {
        if next == nil, let highest, index <= highest { return }
        let advancing = highest == nil || index > highest!
        highest = max(highest ?? index, index)
        if let next, index < next {
            late += 1
            if advancing { lateStreak += 1 }
            guard lateStreak >= 3 else { return }
            rebuffer()
        }
        lateStreak = 0
        if let next, UInt64(index) > UInt64(next) + 50 { rebuffer() }
        if next == nil { next = index; start = now + delay }
        if UInt64(index) <= UInt64(next!) + 15 { frames[index] = data }
    }

    mutating func pop(now: TimeInterval) -> (packet: Data?, following: Data?)? {
        guard let index = next, now >= start else { return nil }
        next = index &+ 1
        let packet = frames.removeValue(forKey: index)
        let following = frames[index &+ 1]
        if packet == nil { lost += 1; misses += 1 } else { misses = 0 }
        if misses >= 3 && frames.isEmpty { rebuffer() }
        return (packet, following)
    }
}
