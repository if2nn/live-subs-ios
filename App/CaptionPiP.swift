import AVKit
import AVFoundation
import UIKit
import ReplayKit
import Observation

/// Sample-buffer Picture in Picture for captions.
///
/// Design rules learned from preview 2/3 device logs:
/// - ONE layer and ONE AVPictureInPictureController for the app's lifetime,
///   created as soon as the layer is in a window. Recreating the controller on
///   every tap resets isPictureInPicturePossible (preview 3 never popped).
/// - No readiness gate on isReadyForDisplay; the only precondition for
///   startPictureInPicture is the controller's isPictureInPicturePossible.
/// - IOSurface 32BGRA frames with DisplayImmediately, fed continuously.
/// - A failed renderer (-11847 when backgrounded) is flushed and fed again.
@MainActor @Observable
final class CaptionPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
 var status = "点「开始」：开启悬浮字幕，再在系统面板里开始录屏"
 var isActive = false
 var isPossible = false
 var armed = false
 var phase: BroadcastPhase = .idle
 var captureStatus = "未开始录屏"
 var caption = Caption()
 var settings = AppSettings()
 /// Pixel size of the last frame sent to PiP, e.g. "1440x480 @3x" (diagnostics, UI tests).
 var frameLabel = ""

 let layer = AVSampleBufferDisplayLayer()
 @ObservationIgnored private var controller: AVPictureInPictureController?
 @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
 @ObservationIgnored private var timebase: CMTimebase?
 private let renderer = CaptionRenderer()
 @ObservationIgnored private var renderPolicy = PiPRenderPolicy()
 @ObservationIgnored private var startPolicy = PiPStartPolicy()
 @ObservationIgnored private var ticker: Task<Void, Never>?
 @ObservationIgnored private var lastContent: CaptionRenderer.Content?
 @ObservationIgnored private var lastRender = 0.0
 @ObservationIgnored private var forceRender = true
 @ObservationIgnored private var lastSnapshotRead = 0.0
 @ObservationIgnored private var everRan = false
 @ObservationIgnored private var loggedFirstFrame = false
 @ObservationIgnored private var observers: [NSObjectProtocol] = []
 private let keepAlive = SilentAudio()
 @ObservationIgnored weak var surface: UIView?
 let launcher = BroadcastLauncher()

 override init() {
  super.init()
  var tb: CMTimebase?
  CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
  if let tb {
   CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
   CMTimebaseSetRate(tb, rate: 1)
   layer.controlTimebase = tb
  }
  timebase = tb
  layer.videoGravity = .resizeAspect
  layer.backgroundColor = UIColor.black.cgColor
  let center = NotificationCenter.default
  observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { @Sendable note in
   let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
   Task { @MainActor [weak self] in if ended { self?.resumeAudioIfNeeded() } }
  })
  observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { @Sendable _ in
   Task { @MainActor [weak self] in self?.forceRender = true; self?.recoverRendererIfNeeded() }
  })
  startTicker()
 }

 isolated deinit {
  ticker?.cancel()
  observers.forEach { NotificationCenter.default.removeObserver($0) }
 }

 #if DEBUG
 /// UI tests only (--ui-testing-seed-caption): a fixed bilingual caption and
 /// a PNG of the first rendered frame per size in Documents, so CI keeps
 /// pixel-exact evidence of the strip. Not device evidence of PiP sharpness.
 func enableCaptionFixture() {
  var c = Caption(original: "We tested the floating captions on a real phone today.",
                  translated: "今天我们在真机上测试了悬浮字幕。", status: "UI test", seq: 1, session: "UITEST")
  c.originalLive = c.original; c.translatedLive = c.translated
  caption = c
  fixture = true
  renderer.debugFrameSink = { canvas, png in
   guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
   try? png.write(to: docs.appendingPathComponent("caption-frame-\(canvas.pixelWidth)x\(canvas.pixelHeight).png"))
  }
  forceRender = true
 }
 @ObservationIgnored private var fixture = false
 #endif

 // MARK: Layer hosting

 func attach(to view: UIView) {
  surface = view
  let scale = Double(view.traitCollection.displayScale)
  if scale >= 1 { renderer.screenScale = scale }
  Diagnostics.record("pip.screen.scale", code: Int((renderer.screenScale * 100).rounded()))
  Diagnostics.record("pip.attach.before")
  if layer.superlayer !== view.layer { view.layer.addSublayer(layer) }
  layer.frame = view.bounds
  Diagnostics.record(layer.superlayer === view.layer ? "pip.attach.success" : "pip.attach.failure")
  forceRender = true
  render(now: CACurrentMediaTime())
  ensureController()
 }

 private func ensureController() {
  guard controller == nil else { return }
  guard AVPictureInPictureController.isPictureInPictureSupported() else {
   status = "此设备不支持画中画"; Diagnostics.record("pip.unsupported"); return
  }
  Diagnostics.record("pip.controller.before")
  let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
  let c = AVPictureInPictureController(contentSource: source)
  c.delegate = self
  c.requiresLinearPlayback = true
  c.canStartPictureInPictureAutomaticallyFromInline = armed
  controller = c
  possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { @Sendable observed, _ in
   let possible = observed.isPictureInPicturePossible
   Task { @MainActor [weak self] in
    guard let self else { return }
    if self.isPossible != possible { Diagnostics.record("pip.possible", code: possible ? 1 : 0) }
    self.isPossible = possible
    self.stepStart()
   }
  }
  Diagnostics.record("pip.controller.success")
 }

 // MARK: User actions

 /// The Para-style one tap: arm auto-PiP, start PiP now if possible, then
 /// open the system broadcast picker. Starting the broadcast itself always
 /// needs the user's tap in the system sheet (ReplayKit has no public API).
 func oneTapStart() {
  arm()
  startPictureInPicture()
  Task { @MainActor [weak self] in
   try? await Task.sleep(for: .milliseconds(600))
   guard let self else { return }
   if self.launcher.open() {
    Diagnostics.record("broadcast.picker.opened")
    if self.phase != .running { self.status = "在系统面板选「双语字幕」并点「开始直播」" }
   } else {
    Diagnostics.record("broadcast.picker.unavailable")
    self.status = "请点下方录屏按钮，选「双语字幕」开始直播"
   }
  }
 }

 func arm() {
  armed = true
  controller?.canStartPictureInPictureAutomaticallyFromInline = true
  activateAudio()
 }

 func startPictureInPicture() {
  Diagnostics.record("pip.start.requested")
  guard let surface, surface.window != nil else {
   status = "请在字幕页前台开启"; Diagnostics.record("pip.surface.unavailable"); return
  }
  layer.frame = surface.bounds
  ensureController()
  guard controller != nil else { return }
  activateAudio()
  forceRender = true
  render(now: CACurrentMediaTime())
  if controller?.isPictureInPictureActive == true { status = "悬浮字幕已开启"; return }
  let action = startPolicy.request(now: CACurrentMediaTime(), possible: isPossible, appActive: appActive)
  apply(action)
 }

 func stopAll() {
  armed = false
  startPolicy.cancel()
  controller?.canStartPictureInPictureAutomaticallyFromInline = false
  Diagnostics.record("pip.stop.before")
  controller?.stopPictureInPicture()
  Diagnostics.record("pip.stop.returned")
  keepAlive.stop()
  status = phase == .running ? "悬浮字幕已关闭；录屏仍在系统里进行，可再点「开始」" : "已停止"
 }

 /// Opens the system picker again; its sheet offers "停止直播" while recording.
 func openRecorder() {
  if !launcher.open() { status = "请点录屏按钮" }
 }

 private var fixtureActive: Bool {
  #if DEBUG
  return fixture
  #else
  return false
  #endif
 }

 private var appActive: Bool { UIApplication.shared.applicationState == .active }

 private func apply(_ action: PiPStartPolicy.Action) {
  switch action {
  case .start:
   guard let controller else { return }
   status = "正在开启悬浮字幕…"
   Diagnostics.record("pip.start.before")
   controller.startPictureInPicture()
   Diagnostics.record("pip.start.returned")
  case .wait:
   status = "系统正在准备悬浮字幕…"
  case .gaveUpNotPossible:
   Diagnostics.record("pip.start.notPossible")
   status = armed ? "系统暂不允许开启；离开 App 时会自动进入悬浮字幕" : "系统暂不允许开启悬浮字幕，请再点一次"
  case .gaveUpNoCallback:
   Diagnostics.record("pip.start.noCallback")
   status = "系统未响应开启请求，请再点一次"
  case .none:
   break
  }
 }

 private func stepStart() {
  guard startPolicy.pending else { return }
  apply(startPolicy.step(now: CACurrentMediaTime(), possible: isPossible, appActive: appActive))
 }

 // MARK: Audio session (required for PiP) and background keep-alive

 private func activateAudio() {
  do {
   Diagnostics.record("pip.audio.category.before")
   try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
   Diagnostics.record("pip.audio.category.success")
   Diagnostics.record("pip.audio.active.before")
   try AVAudioSession.sharedInstance().setActive(true)
   Diagnostics.record("pip.audio.active.success")
   // Silent playback keeps the process running while PiP is shown over
   // other apps, so caption frames keep updating. Device-verification item.
   keepAlive.start()
  } catch {
   Diagnostics.record("pip.audio.active.failure", code: (error as NSError).code)
   status = "音频会话启动失败，悬浮字幕可能无法开启"
  }
 }
 private func resumeAudioIfNeeded() {
  guard armed || isActive else { return }
  activateAudio()
 }

 // MARK: Ticker: caption IPC, broadcast phase, rendering

 private func startTicker() {
  ticker = Task { @MainActor [weak self] in
   while !Task.isCancelled {
    self?.tick()
    try? await Task.sleep(for: .milliseconds(200))
   }
  }
 }

 private func tick() {
  let now = CACurrentMediaTime()
  if !fixtureActive, let latest = Store.read(), latest.seq != caption.seq || latest.session != caption.session || latest.original != caption.original || latest.translated != caption.translated || latest.status != caption.status {
   caption = latest
  }
  if now - lastSnapshotRead >= 1 {
   lastSnapshotRead = now
   let snapshot = CaptureIPC.read()
   let shared = Store.root != nil
   captureStatus = CaptureIPC.status(snapshot, sharedAvailable: shared)
   let age = snapshot.map { Date().timeIntervalSince($0.heartbeat) }
   let next = BroadcastPhase.from(lifecycle: snapshot?.lifecycle, heartbeatAge: age, everRan: everRan)
   if next != phase { phaseChanged(from: phase, to: next) }
  }
  stepStart()
  recoverRendererIfNeeded()
  render(now: now)
 }

 private func phaseChanged(from old: BroadcastPhase, to new: BroadcastPhase) {
  phase = new
  Diagnostics.record("broadcast.phase", code: [.idle: 0, .running: 1, .stopped: 2, .stale: 3][new] ?? -1)
  switch new {
  case .running:
   everRan = true
   status = isActive ? "正在录屏，字幕显示在悬浮窗" : "录屏已开始；离开 App 后进入悬浮字幕"
   // Broadcast just started while we are still in front: try PiP again.
   if armed && !isActive && appActive { startPictureInPicture() }
  case .stopped, .stale:
   if old == .running || everRan {
    status = new == .stopped ? "录屏已停止。点「开始」重新开启" : "录屏信号中断，可能已停止。点「开始」重新开启"
   }
  case .idle:
   break
  }
  forceRender = true
 }

 private var notice: String {
  switch phase {
  case .stopped: return "录屏已停止 · 回到双语字幕点「开始」重开"
  case .stale: return "录屏信号中断 · 回到 App 重新开始"
  case .idle: return armed ? "等待系统录屏开始…" : "双语字幕 · 未在录屏"
  case .running:
   if caption.original.isEmpty && caption.translated.isEmpty { return captureStatus }
   return ""
  }
 }

 private func currentContent() -> CaptionRenderer.Content {
  let stale = phase != .running
  return CaptionRenderer.Content(original: stale && caption.original.isEmpty ? "" : caption.original,
   translated: caption.translated, originalLive: caption.originalLive ?? "", translatedLive: caption.translatedLive ?? "",
   notice: notice, settings: settings)
 }

 private func render(now: Double) {
  let content = currentContent()
  let changed = forceRender || content != lastContent
  // Re-feed the same frame once a second so the layer always has fresh media.
  guard changed || now - lastRender >= 1 else { return }
  guard layer.status != .failed else { return }
  guard let pixel = renderer.render(content) else { Diagnostics.record("pip.frame.unavailable"); return }
  var format: CMVideoFormatDescription?
  CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
  guard let format else { return }
  let host = timebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
  let pts = CMTime(value: renderPolicy.nextTick(hostSeconds: CMTimeGetSeconds(host)), timescale: 60000)
  var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
                                           sampleTiming: &timing, sampleBufferOut: &sample)
  guard let sample else { return }
  if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
   let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
   CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
  }
  guard layer.isReadyForMoreMediaData else { return }
  let label = renderer.lastCanvas?.label ?? ""
  if !loggedFirstFrame || label != frameLabel {
   Diagnostics.record("pip.frame.width", code: CVPixelBufferGetWidth(pixel))
   Diagnostics.record("pip.frame.height", code: CVPixelBufferGetHeight(pixel))
   Diagnostics.record("pip.frame.scale", code: Int(((renderer.lastCanvas?.scale ?? 0) * 100).rounded()))
   Diagnostics.record("pip.frame.subtype", code: Int(CMFormatDescriptionGetMediaSubType(format)))
   frameLabel = label
  }
  layer.enqueue(sample)
  lastContent = content; lastRender = now; forceRender = false
  if !loggedFirstFrame {
   loggedFirstFrame = true
   Diagnostics.record(layer.status == .failed ? "pip.frame.first.failure" : "pip.frame.first.success")
  }
 }

 private func recoverRendererIfNeeded() {
  guard layer.status == .failed || layer.requiresFlushToResumeDecoding else { return }
  let count = renderPolicy.failed()
  if count <= 3 || count % 20 == 0 {
   Diagnostics.record("pip.renderer.failed", code: count)
   if let error = layer.error { Diagnostics.recordRendererError(error) }
  }
  layer.flush()
  Diagnostics.record("pip.renderer.flush")
  forceRender = true
  loggedFirstFrame = false
  if layer.status != .failed { renderPolicy.recovered() }
 }

 // MARK: AVPictureInPictureSampleBufferPlaybackDelegate (live, never paused)

 nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
  Diagnostics.record("pip.delegate.playing")
 }
 nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
  CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
 }
 nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
 /// AVKit reports the PiP window's render size in pixels. Re-render the strip
 /// at exactly the pixels it occupies there so text is never resampled.
 nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
  let w = Int(newRenderSize.width), h = Int(newRenderSize.height)
  Diagnostics.record("pip.renderSize.width", code: w)
  Diagnostics.record("pip.renderSize.height", code: h)
  Task { @MainActor [weak self] in
   guard let self else { return }
   self.renderer.renderSize = (w > 0 && h > 0) ? (w, h) : nil
   self.forceRender = true
   self.render(now: CACurrentMediaTime())
  }
 }
 nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
  completionHandler()
 }

 // MARK: AVPictureInPictureControllerDelegate

 nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
  Diagnostics.record("pip.delegate.willStart")
  let at = CACurrentMediaTime()
  Task { @MainActor [weak self] in self?.startPolicy.willStart(now: at) }
 }
 nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
  Diagnostics.record("pip.delegate.didStart")
  Task { @MainActor [weak self] in
   guard let self else { return }
   self.startPolicy.didStart()
   self.isActive = true
   self.status = self.phase == .running ? "悬浮字幕已开启，正在录屏" : "悬浮字幕已开启；在系统面板开始录屏"
   self.forceRender = true
  }
 }
 nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
  let code = (error as NSError).code
  Diagnostics.record("pip.delegate.failedStart", code: code)
  Task { @MainActor [weak self] in
   guard let self else { return }
   self.startPolicy.failed()
   self.status = "悬浮字幕启动失败（\(code)），请再点一次"
  }
 }
 nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
  Diagnostics.record("pip.delegate.didStop")
  Task { @MainActor [weak self] in
   guard let self else { return }
   self.startPolicy.didStop()
   self.isActive = false
   if self.armed { self.status = "悬浮字幕已关闭；点「开始」可再次开启" }
   self.renderer.renderSize = nil
   self.forceRender = true
  }
 }
 nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
  Diagnostics.record("pip.delegate.restore")
  completionHandler(true)
 }
}

/// Plays digital silence while captions are armed. Without some audio
/// playback iOS may suspend the app in the background and stop caption updates.
@MainActor
final class SilentAudio {
 private let engine = AVAudioEngine()
 private let player = AVAudioPlayerNode()
 private var configured = false
 private(set) var running = false
 func start() {
  guard !running else { return }
  guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050) else { return }
  buffer.frameLength = 22_050
  if let channel = buffer.floatChannelData { channel[0].update(repeating: 0, count: Int(buffer.frameLength)) }
  if !configured {
   engine.attach(player)
   engine.connect(player, to: engine.mainMixerNode, format: format)
   configured = true
  }
  do {
   try engine.start()
   player.scheduleBuffer(buffer, at: nil, options: .loops)
   player.play()
   running = true
   Diagnostics.record("keepalive.started")
  } catch {
   Diagnostics.record("keepalive.failed", code: (error as NSError).code)
  }
 }
 func stop() {
  guard running else { return }
  player.stop(); engine.stop(); running = false
  Diagnostics.record("keepalive.stopped")
 }
}

/// Holds the visible RPSystemBroadcastPickerView. `open()` sends the picker's
/// own button action (public UIControl API) so one tap can raise the system
/// sheet; if the picker's view structure ever changes, the user taps it directly.
@MainActor
final class BroadcastLauncher {
 weak var picker: RPSystemBroadcastPickerView?
 func open() -> Bool {
  guard let picker, let button = Self.button(in: picker) else { return false }
  button.sendActions(for: .touchUpInside)
  return true
 }
 private static func button(in view: UIView) -> UIButton? {
  for sub in view.subviews {
   if let b = sub as? UIButton { return b }
   if let b = button(in: sub) { return b }
  }
  return nil
 }
}
