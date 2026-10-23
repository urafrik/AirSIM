import Foundation

let recorder = LocalCallPCMRecorder()
try recorder.start()
recorder.append(Data(repeating: 0x11, count: 320), uplink: true)
recorder.append(Data(repeating: 0x22, count: 320), uplink: false)
let done = DispatchSemaphore(value: 0)
var saved: URL?
var failure: Error?
recorder.stop { result in
    switch result {
    case let .success(url): saved = url
    case let .failure(error): failure = error
    }
    done.signal()
}
precondition(done.wait(timeout: .now() + 10) == .success)
if let failure { throw failure }
let file = saved!
defer { try? FileManager.default.removeItem(at: file) }
let data = try Data(contentsOf: file)
precondition(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
precondition(String(data: data[8..<12], encoding: .ascii) == "WAVE")
precondition(data[22] == 2 && data[23] == 0)
let frames = stride(from: 44, to: data.count - 3, by: 4)
precondition(frames.contains { data[$0] == 0x11 && data[$0 + 1] == 0x11 })
precondition(frames.contains { data[$0 + 2] == 0x22 && data[$0 + 3] == 0x22 })
let expectedSize = UInt32(data.count - 44)
let encodedSize = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[40 + $1]) << ($1 * 8) }
precondition(encodedSize == expectedSize)
let stopped = DispatchSemaphore(value: 0)
recorder.stop { result in
    if case let .success(url) = result { precondition(url == nil) }
    else { preconditionFailure("Repeated stop failed") }
    stopped.signal()
}
precondition(stopped.wait(timeout: .now() + 5) == .success)
print("PASS local stereo WAV recording: two channels, valid header, repeated stop")
