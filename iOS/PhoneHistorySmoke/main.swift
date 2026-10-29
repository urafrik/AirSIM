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
