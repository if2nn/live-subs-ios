import Foundation

/// Host-media ticks only, never Date. PTS strictly increases across recovery.
struct PiPRenderPolicy {
 private(set) var lastTick: Int64?
 private(set) var failures = 0
 mutating func nextTick(hostSeconds: Double) -> Int64 {
  let current = Int64((hostSeconds * 60000).rounded(.down))
  let next = max(current, lastTick.map { $0 + 1 } ?? current)
  lastTick = next
  return next
 }
 /// A failed renderer is flushed and fed again. The layer and the PiP
 /// controller are never recreated: replacing either invalidates the
 /// system's PiP possibility and was the preview 3 failure mode.
 mutating func failed() -> Int { failures += 1; return failures }
 mutating func recovered() { failures = 0 }
}

/// One user tap = one start request. No readiness gate on isReadyForDisplay:
/// the controller's own isPictureInPicturePossible is the only precondition.
/// The controller is persistent; this policy only times a request.
struct PiPStartPolicy {
 enum Action: Equatable { case none, start, wait, gaveUpNotPossible, gaveUpNoCallback }
 static let possibleDeadline = 4.0
 static let callbackDeadline = 3.0
 private(set) var requestedAt: Double?
 private(set) var calledAt: Double?
 private(set) var calls = 0
 private(set) var active = false

 /// Returns .start when the system already reports PiP possible.
 mutating func request(now: Double, possible: Bool, appActive: Bool) -> Action {
  requestedAt = now; calledAt = nil; calls = 0
  return step(now: now, possible: possible, appActive: appActive)
 }
 mutating func step(now: Double, possible: Bool, appActive: Bool) -> Action {
  guard let requested = requestedAt, !active else { return .none }
  if let called = calledAt {
   guard now - called >= Self.callbackDeadline else { return .wait }
   // One silent retry if the system dropped the first call, still on the same tap.
   if calls < 2 && possible && appActive && now - requested < Self.possibleDeadline + Self.callbackDeadline {
    calledAt = now; calls += 1; return .start
   }
   requestedAt = nil; calledAt = nil
   return .gaveUpNoCallback
  }
  if possible && appActive { calledAt = now; calls += 1; return .start }
  guard now - requested < Self.possibleDeadline else { requestedAt = nil; return .gaveUpNotPossible }
  return .wait
 }
 /// The system accepted the call; wait for didStart, never re-issue start.
 mutating func willStart(now: Double) { if requestedAt != nil { calledAt = now; calls = 2 } }
 mutating func didStart() { active = true; requestedAt = nil; calledAt = nil }
 mutating func didStop() { active = false; requestedAt = nil; calledAt = nil }
 mutating func failed() { requestedAt = nil; calledAt = nil }
 mutating func cancel() { requestedAt = nil; calledAt = nil }
 var pending: Bool { requestedAt != nil }
}

/// What the main app should show about the broadcast, derived from heartbeat
/// state only. Recording stop prompts reopen; it never claims capture works.
enum BroadcastPhase: Equatable {
 case idle, running, stopped, stale
 static func from(lifecycle: String?, heartbeatAge: Double?, everRan: Bool) -> BroadcastPhase {
  guard let lifecycle, let age = heartbeatAge else { return everRan ? .stopped : .idle }
  if lifecycle == "stopped" || lifecycle == "failed" { return .stopped }
  if age > 10 { return everRan ? .stale : .idle }
  return .running
 }
}
