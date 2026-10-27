import Foundation

var jitter = UDPOpusJitterBuffer()
jitter.push(0, data: Data([1]), now: 0)
for tick in 0..<20 { _ = jitter.pop(now: 0.061 + Double(tick)*0.02) }
var recovered = 0
for index in 1...100 {
    let now = 0.5 + Double(index)*0.02
    jitter.push(UInt32(index), data: Data([2]), now: now)
    if let item = jitter.pop(now: now), item.packet != nil { recovered += 1 }
}
precondition(recovered > 80, "Late stream must recover instead of perpetual PLC")
precondition(jitter.delay <= 0.12 && jitter.rebuffers < 5)

var reorder = UDPOpusJitterBuffer()
reorder.push(0, data: Data([0]), now: 0)
reorder.push(2, data: Data([2]), now: 0.01)
precondition(reorder.pop(now: 0.02) == nil)
precondition(reorder.pop(now: 0.061)?.packet == Data([0]))
let loss = reorder.pop(now: 0.081)
precondition(loss?.packet == nil && loss?.following == Data([2]))
reorder.push(1, data: Data([1]), now: 0.09)
precondition(reorder.late == 1)
precondition(reorder.pop(now: 0.101)?.packet == Data([2]))
print("PASS: actual Swift jitter policy handles loss, reordering and sustained lateness")
