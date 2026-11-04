import Foundation

/// Host-media ticks only, never Date. Recovery never resets PTS.
struct PiPRenderPolicy {
 enum Recovery: Equatable { case flush, rebuild, deferRebuild }
 private(set) var lastTick: Int64?
 private(set) var failures = 0
 mutating func nextTick(hostSeconds: Double) -> Int64 {
  let current = Int64((hostSeconds * 60000).rounded(.down))
  let next = max(current, lastTick.map { $0 + 1 } ?? current)
  lastTick = next
  return next
 }
 mutating func failed(active: Bool) -> Recovery {
  failures += 1
  if failures < 2 { return .flush }
  return active ? .deferRebuild : .rebuild
 }
 mutating func rebuilt() { failures = 0 }
}

/// Cancellation revokes authorization; diagnostic timeout does not.
struct PiPPolicy {
 enum Action: Equatable { case wait, start, retry, timeoutReadiness, timeoutDelegate, timeoutDidStart, cancelled }
 enum StartResult: Equatable { case accepted, late, rejected }
 private(set) var token = UUID()
 private(set) var valid = false
 private(set) var retryValid = false
 private(set) var acceptDidStart = false
 private(set) var requestedAt = 0.0
 private(set) var calledAt: Double?
 private(set) var willStartAt: Double?
 private(set) var retries = 0
 private(set) var sawDelegate = false
 private(set) var started = false
 private(set) var timedOut = false
 mutating func begin(now: Double) -> UUID {
  token=UUID(); valid=true; retryValid=true; acceptDidStart=false
  requestedAt=now; calledAt=nil; willStartAt=nil; retries=0
  sawDelegate=false; started=false; timedOut=false
  return token
 }
 mutating func cancel() { valid=false; retryValid=false; acceptDidStart=false }
 mutating func background() {
  retryValid=false
  if calledAt == nil { valid=false; acceptDidStart=false }
 }
 mutating func willStart(now: Double) {
  guard acceptDidStart else { return }
  sawDelegate=true; retryValid=false
  if willStartAt == nil { willStartAt=now }
 }
 mutating func didStart() -> StartResult {
  guard acceptDidStart else { return .rejected }
  let result: StartResult = timedOut ? .late : .accepted
  sawDelegate=true; started=true; valid=false; retryValid=false
  return result
 }
 mutating func step(now: Double, active: Bool, ready: Bool, possible: Bool) -> Action {
  if !active { background() }
  guard valid else { return .cancelled }
  if let will=willStartAt {
   guard now-will >= 6 else { return .wait }
   valid=false; retryValid=false; timedOut=true
   return .timeoutDidStart
  }
  if let call=calledAt {
   guard now-call >= 2 else { return .wait }
   if retryValid && !sawDelegate && retries == 0 && now-requestedAt < 5 {
    retries=1; calledAt=nil; acceptDidStart=false
    return .retry
   }
   valid=false; retryValid=false; timedOut=true
   return .timeoutDelegate
  }
  guard now-requestedAt < 6 else {
   valid=false; retryValid=false; timedOut=true
   return .timeoutReadiness
  }
  guard active && retryValid && ready && possible else { return .wait }
  calledAt=now; acceptDidStart=true
  return .start
 }
}
