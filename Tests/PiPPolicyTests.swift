import Foundation

@main
struct PiPPolicyTests {
 static func main() {
  // First tap when the system already reports possible: start immediately,
  // with no readiness (isReadyForDisplay) gate. This is the preview 3 fix.
  var p = PiPStartPolicy()
  precondition(p.request(now: 0, possible: true, appActive: true) == .start)
  precondition(p.calls == 1 && p.pending)
  precondition(p.step(now: 1, possible: true, appActive: true) == .wait)
  p.willStart(now: 1.2)
  precondition(p.step(now: 3.9, possible: true, appActive: true) == .wait)
  p.didStart()
  precondition(p.active && !p.pending)
  precondition(p.step(now: 5, possible: true, appActive: true) == .none)
  p.didStop()
  precondition(!p.active)

  // Not yet possible: wait (KVO will step again), start as soon as possible flips.
  p = PiPStartPolicy()
  precondition(p.request(now: 10, possible: false, appActive: true) == .wait)
  precondition(p.step(now: 11, possible: false, appActive: true) == .wait)
  precondition(p.step(now: 11.5, possible: true, appActive: true) == .start)
  // System never answers: exactly one silent retry on the same tap, then give up.
  precondition(p.step(now: 14.6, possible: true, appActive: true) == .start)
  precondition(p.calls == 2)
  precondition(p.step(now: 17.7, possible: true, appActive: true) == .gaveUpNoCallback)
  precondition(!p.pending)
  precondition(p.step(now: 18, possible: true, appActive: true) == .none)

  // Never possible within the deadline: give up with a clear message.
  p = PiPStartPolicy()
  precondition(p.request(now: 20, possible: false, appActive: true) == .wait)
  precondition(p.step(now: 23.9, possible: false, appActive: true) == .wait)
  precondition(p.step(now: 24.1, possible: false, appActive: true) == .gaveUpNotPossible)

  // Backgrounded before possible: never issue a start from the background.
  p = PiPStartPolicy()
  precondition(p.request(now: 30, possible: true, appActive: false) == .wait)
  precondition(p.step(now: 31, possible: true, appActive: false) == .wait)
  precondition(p.step(now: 31.5, possible: true, appActive: true) == .start)

  // After willStart the policy never re-issues a start, even if didStart is late.
  p = PiPStartPolicy()
  precondition(p.request(now: 40, possible: true, appActive: true) == .start)
  p.willStart(now: 40.5)
  precondition(p.step(now: 43.6, possible: true, appActive: true) == .gaveUpNoCallback)
  p.didStart()
  precondition(p.active)

  // Failure and cancel clear the request; a new tap starts fresh.
  p = PiPStartPolicy()
  precondition(p.request(now: 50, possible: true, appActive: true) == .start)
  p.failed()
  precondition(!p.pending && p.step(now: 51, possible: true, appActive: true) == .none)
  precondition(p.request(now: 52, possible: true, appActive: true) == .start)
  p.cancel()
  precondition(!p.pending)

  // PTS ticks strictly increase even if the host clock repeats or goes back.
  var r = PiPRenderPolicy()
  let a = r.nextTick(hostSeconds: 1000)
  let b = r.nextTick(hostSeconds: 1000)
  let c = r.nextTick(hostSeconds: 999)
  precondition(a < b && b < c)
  precondition(r.failed() == 1 && r.failed() == 2)
  r.recovered()
  precondition(r.failures == 0 && r.nextTick(hostSeconds: 1000.5) > c)

  // Broadcast phase from heartbeat only: stop prompts reopen; idle is not "stopped".
  precondition(BroadcastPhase.from(lifecycle: nil, heartbeatAge: nil, everRan: false) == .idle)
  precondition(BroadcastPhase.from(lifecycle: nil, heartbeatAge: nil, everRan: true) == .stopped)
  precondition(BroadcastPhase.from(lifecycle: "started", heartbeatAge: 2, everRan: false) == .running)
  precondition(BroadcastPhase.from(lifecycle: "started", heartbeatAge: 12, everRan: true) == .stale)
  precondition(BroadcastPhase.from(lifecycle: "started", heartbeatAge: 12, everRan: false) == .idle)
  precondition(BroadcastPhase.from(lifecycle: "stopped", heartbeatAge: 1, everRan: false) == .stopped)
  precondition(BroadcastPhase.from(lifecycle: "failed", heartbeatAge: 1, everRan: true) == .stopped)
  print("PiPPolicyTests PASS (start policy, PTS, broadcast phase; not AVKit/device validation)")
 }
}
