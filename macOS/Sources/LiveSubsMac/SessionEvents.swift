import Foundation

/// All socket-origin events are yielded on Soniox.queue. Only this stream's
/// single MainActor consumer mutates transcript state.
enum SessionEvent: Sendable {
 case message(Data)
 case reconnect
 case firstAudio(Date)
 case fatal(String)
 case barrier(CheckedContinuation<Void, Never>)
}

struct ConnectionTimeline: Sendable {
 private(set) var offsetMS = 0
 mutating func firstAudio(at date: Date, sessionStart: Date) {
  offsetMS = max(0, Int(date.timeIntervalSince(sessionStart) * 1000))
 }
}
