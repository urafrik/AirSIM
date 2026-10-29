import Foundation

let now = Date(timeIntervalSince1970: 1_700_000_000)
let incoming = SMSMessage(sender: "10086", content: "one", code: nil, timestamp: now, deliveryID: "1")
let another = SMSMessage(sender: "10010", content: "two", code: nil, timestamp: now, deliveryID: "2")
let outgoing = SMSMessage(sender: "10086", content: "reply", code: nil, timestamp: now, direction: .outgoing)
let all = [incoming, another, outgoing]
var readIDs = Set<String>()
precondition(SMSReadPolicy.isUnread(incoming, readIDs: readIDs))
precondition(!SMSReadPolicy.isUnread(outgoing, readIDs: readIDs))
readIDs = SMSReadPolicy.updating(readIDs, messages: all, sender: "10086", read: true)
precondition(!SMSReadPolicy.isUnread(incoming, readIDs: readIDs))
precondition(SMSReadPolicy.isUnread(another, readIDs: readIDs))
// Repeated agent delivery retains the same read state, without changing message identity.
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let reloaded = try decoder.decode(SMSMessage.self, from: encoder.encode(incoming))
precondition(!SMSReadPolicy.isUnread(reloaded, readIDs: readIDs))
precondition(reloaded.receivedAt == nil && reloaded.displayTimestamp == now)
var delayed = incoming
delayed.receivedAt = now.addingTimeInterval(120)
precondition(delayed.id == incoming.id) // Receipt metadata never creates a duplicate.
precondition(delayed.displayTimestamp == now.addingTimeInterval(120))
readIDs = SMSReadPolicy.updating(readIDs, messages: all, sender: "10086", read: false)
precondition(SMSReadPolicy.isUnread(incoming, readIDs: readIDs))
readIDs = SMSReadPolicy.updating(readIDs, messages: all, sender: nil, read: true)
precondition(!all.contains { SMSReadPolicy.isUnread($0, readIDs: readIDs) })

let legacy = #"{"id":"old","index":1,"direction":"outgoing","state":"ended","number":"10086","started_at":"2026-10-29T01:00:00Z","updated_at":"2026-10-29T01:01:00Z","ended_at":"2026-10-29T01:01:00Z","missed":false}"#
let oldCall = try decoder.decode(CallRecord.self, from: Data(legacy.utf8))
precondition(oldCall.wasConnected == nil && !oldCall.isUnanswered)
precondition(oldCall.outcomeTitle == "呼出") // Never invent an outcome for old records.
var call = oldCall
call.wasConnected = false
precondition(call.isUnanswered && call.outcomeTitle == "呼出未接通")
call.wasConnected = true
call.connectedAt = now
precondition(!call.isUnanswered && call.outcomeTitle == "呼出已接通")
let missedJSON = legacy.replacingOccurrences(of: "outgoing", with: "incoming")
    .replacingOccurrences(of: "\"missed\":false", with: "\"missed\":true")
let missed = try decoder.decode(CallRecord.self, from: Data(missedJSON.utf8))
precondition(missed.isUnanswered && missed.outcomeTitle == "未接来电")
print("PASS: SMS unread persistence, per-thread/all read actions, outgoing exclusion, old call decoding and outcomes")

// Regression: the legacy sent ID used sub-second Date but disk ISO8601 rounded it.
let fractional = SMSMessage(sender: "10086", content: "hi", code: nil, timestamp: now.addingTimeInterval(0.123), direction: .outgoing)
let roundedCopy = try decoder.decode(SMSMessage.self, from: encoder.encode(fractional))
precondition(fractional.id != roundedCopy.id)
let repaired = SMSHistoryPolicy.canonicalized([fractional, roundedCopy])
precondition(repaired.count == 1)
let onDisk = try decoder.decode([SMSMessage].self, from: encoder.encode(repaired))
precondition(onDisk[0].id == repaired[0].id)
precondition(SMSHistoryPolicy.canonicalized(repaired + onDisk).count == 1)
var sent = SMSHistoryPolicy.appendingSentMessage(recipient: "10086", content: "hi", at: now, to: [], limit: 3000)
sent = SMSHistoryPolicy.appendingSentMessage(recipient: "10086", content: "hi", at: now, to: sent, limit: 3000)
precondition(sent.count == 2 && sent[0].id != sent[1].id) // Genuine repeated sends stay separate.
precondition(SMSHistoryPolicy.canonicalized(sent).count == 2)

var providerSMS = SMSMessage(sender: "10086", content: "hi", code: nil, timestamp: now.addingTimeInterval(1),
    deliveryID: "android-history-phone-sms-1", direction: .outgoing)
providerSMS.androidHistoryID = "android-history-phone-sms-1"
let oneLocal = [sent[0]]
let mergedSent = AndroidHistoryMerge.messages(local: oneLocal, imported: [providerSMS])
precondition(mergedSent.count == 1 && mergedSent[0].id == sent[0].id)
precondition(AndroidHistoryMerge.messages(local: mergedSent, imported: [providerSMS]).count == 1)
var secondSMS = providerSMS
secondSMS.deliveryID = "android-history-phone-sms-2"
secondSMS.androidHistoryID = "android-history-phone-sms-2"
precondition(AndroidHistoryMerge.messages(local: [], imported: [providerSMS, secondSMS]).count == 2)
precondition(AndroidHistoryMerge.messages(local: sent, imported: [providerSMS, secondSMS]).count == 2)
let many = (0..<2300).map { index -> SMSMessage in
    SMSMessage(sender: "10086", content: "\(index)", code: nil, timestamp: now, deliveryID: "row-\(index)")
}
let mergedMany = AndroidHistoryMerge.messages(local: [], imported: many)
precondition(mergedMany.count == 2300)
precondition(AndroidHistoryMerge.messages(local: mergedMany, imported: many).count == 2300)

var systemCall = oldCall
systemCall.id = "provider-call-1"
systemCall.androidHistoryID = systemCall.id
systemCall.wasConnected = true
systemCall.systemCallType = "outgoing"
let mergedCall = AndroidHistoryMerge.calls(local: [oldCall], imported: [systemCall])
precondition(mergedCall.count == 1 && mergedCall[0].id == oldCall.id && mergedCall[0].wasConnected == true)
precondition(AndroidHistoryMerge.calls(local: mergedCall, imported: [systemCall]).count == 1)
precondition(AndroidHistoryMerge.calls(local: mergedCall, imported: [oldCall])[0].wasConnected == true)
var rejected = missed
rejected.androidHistoryID = "rejected"
rejected.systemCallType = "rejected"
// Native rejected log rows are not missed calls.
let rejectedJSON = missedJSON.replacingOccurrences(of: "\"missed\":true", with: "\"missed\":false")
var declined = try decoder.decode(CallRecord.self, from: Data(rejectedJSON.utf8))
declined.systemCallType = "rejected"; declined.wasConnected = false
precondition(!declined.isMissedIncoming && declined.outcomeTitle == "已拒接")

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
let formatter = ISO8601DateFormatter()
let dstDay = formatter.date(from: "2026-03-08T18:00:00Z")!
let dstBounds = AndroidHistoryRange.custom.bounds(start: dstDay, end: dstDay, now: dstDay, calendar: calendar)!
precondition(dstBounds.1 - dstBounds.0 == 23 * 60 * 60 * 1000)
precondition(AndroidHistoryRange.custom.bounds(start: dstDay.addingTimeInterval(86400), end: dstDay, now: dstDay, calendar: calendar) == nil)
let three = AndroidHistoryRange.threeDays.bounds(start: now, end: now, now: now, calendar: calendar)!
let seven = AndroidHistoryRange.sevenDays.bounds(start: now, end: now, now: now, calendar: calendar)!
precondition(three.1 == seven.1 && seven.0 < three.0)
precondition(AndroidHistoryRange.all.bounds(start: now, end: now)!.1 == Int64.max)
print("PASS: legacy duplicate repair, stable send IDs, deliberate repeats, provider reconciliation, repeated 2300-row imports, call results, inclusive dates and DST")
