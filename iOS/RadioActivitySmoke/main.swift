import Foundation

let state = AirSIMCallActivityAttributes.ContentState(
    callID: "", number: "", displayName: "Android", phase: .standby,
    startedAt: Date(), signalDBM: -85, operatorName: "Carrier", networkMode: "5G",
    radioUpdatedAt: Date(), vowlanOnline: true)
let fresh = state.liveActivityDisplayState(isStale: false)
precondition(fresh.signalDBM == -85 && fresh.radioStatusText == nil)
let stale = state.liveActivityDisplayState(isStale: true)
precondition(stale.signalDBM == nil, "Stale bars must not look current")
precondition(stale.networkMode == "5G" && stale.operatorName == "Carrier")
precondition(stale.radioStatusText == "后台更新已暂停")
precondition(stale.vowlanOnline == true, "Stale alone cannot prove disconnection")
var oldPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
oldPayload.removeValue(forKey: "radioUpdatedAt")
oldPayload.removeValue(forKey: "radioStatusText")
let decoded = try JSONDecoder().decode(AirSIMCallActivityAttributes.ContentState.self,
    from: JSONSerialization.data(withJSONObject: oldPayload))
precondition(decoded.radioUpdatedAt == nil && decoded.networkMode == "5G")
let radio = try JSONDecoder().decode(ModemStatus.self, from: Data("{\"signal_dbm\":-85,\"network_mode\":\"5G\",\"operator\":\"Carrier\"}".utf8))
precondition(radio.signalDBM == -85 && radio.networkMode == "5G" && radio.sampledAt == nil)
print("PASS: current/stale radio display, old activity compatibility and Android radio decoding")
