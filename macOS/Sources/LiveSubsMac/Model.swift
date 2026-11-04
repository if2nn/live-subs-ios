import SwiftUI
import AppKit

@MainActor @Observable
final class MacModel {
 static let shared = MacModel()
 var settings = AppSettings.decode(UserDefaults.standard.data(forKey: "settings")) {
  didSet { UserDefaults.standard.set(settings.encoded(), forKey: "settings") }
 }
 var keyDraft = ""
 var status = "准备聆听"
 var running = false
 var busy = false
 var caption = Caption()
 var history: [HistoryEntry] = []
 var current: HistoryEntry?
 var selectedHistory: String?
 var split = true { didSet { if split { panel?.orderOut(nil) } else { showPanel() } } }
 var error: String?
 private var transcript = Transcript()
 private var client: Soniox?
 private let audio = SystemAudio()
 private var began = Date()
 private var epoch = UUID()
 private var timeline = ConnectionTimeline()
 private var eventTask: Task<Void, Never>?
 private var eventContinuation: AsyncStream<SessionEvent>.Continuation?
 private(set) var hasUnsavedHistory = false
 private let saveHistory: @MainActor (HistoryEntry) throws -> Void
 private let loadHistory: @MainActor () throws -> [HistoryEntry]
 private var lastSave = Date.distantPast
 private var panel: NSPanel?
 private var startFailure: String?

 init(saveHistory: @escaping @MainActor (HistoryEntry) throws -> Void = Archive.save,
      loadHistory: @escaping @MainActor () throws -> [HistoryEntry] = Archive.load,
      readKey: () throws -> String = KeyVault.read) {
  self.saveHistory = saveHistory; self.loadHistory = loadHistory
  do { keyDraft = try readKey(); history = try loadHistory() }
  catch { self.error = error.localizedDescription }
 }
 var viewed: HistoryEntry? {
  if let selectedHistory { return history.first { $0.id == selectedHistory } }
  return current
 }
 func saveKey() {
  do { try KeyVault.save(keyDraft); status = keyDraft.isEmpty ? "Key 已移除" : "Key 已存入钥匙串" }
  catch { self.error = error.localizedDescription }
 }
 func start() async {
  guard !busy, !running else { return }
  guard persist() else { status = "请先重试保存历史，不能开始新会话"; return }
  busy = true; defer { busy = false }
  do {
   let key = try KeyVault.read()
   guard !key.isEmpty else { error = "请先保存 Soniox API Key"; return }
   startFailure = nil; epoch = UUID(); let id = epoch
   began = Date(); timeline = ConnectionTimeline(); transcript = Transcript(); caption = Caption(); selectedHistory = nil
   let language = settings.languages.normalized()
   current = HistoryEntry(id: UUID().uuidString, started: began, updated: began, source: language.source, target: language.target)
   let socket = Soniox()
   connectEvents(socket)
   socket.onStatus = { [weak self] message in Task { @MainActor in
    guard let self, self.epoch == id else { return }; self.status = message
   }}
   client = socket; status = "请求系统音频权限…"
   socket.start(key, config: SonioxConfig.json(language))
   try await audio.start(client: socket) { [weak self] message in Task { @MainActor in
    guard let self, self.epoch == id else { return }; self.error = message
    if self.busy { self.startFailure = message; return }
    await self.stop(); self.status = message
   }}
   await socketBarrier(socket)
   if let startFailure {
    try await audio.stop(); socket.stop(); client = nil
    await socketBarrier(socket); closeEvents(); finalizeCurrent(); _ = persist(); status = startFailure; error = startFailure; return
   }
   running = true; status = "正在聆听系统音频"
   if !split { showPanel() }
  } catch {
   if let client { client.stop(); await socketBarrier(client) }; client = nil
   closeEvents(); finalizeCurrent(); _ = persist()
   self.error = "无法开始采集。请在系统设置的屏幕与系统音频录制中允许 LiveSubs，必要时重新打开 App。\n" + error.localizedDescription
   status = "采集未启动"
  }
 }
 private func receive(_ data: Data, epoch: UUID) {
  guard self.epoch == epoch, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
  var tokens = object["tokens"] as? [[String: Any]] ?? []
  for i in tokens.indices {
   if let start = tokens[i]["start_ms"] as? Int { tokens[i]["start_ms"] = start + timeline.offsetMS }
   if let end = tokens[i]["end_ms"] as? Int { tokens[i]["end_ms"] = end + timeline.offsetMS }
  }
  let segments = transcript.ingest(tokens, arrivalMS: Int(Date().timeIntervalSince(began) * 1000))
  current?.append(segments); hasUnsavedHistory = true; caption = transcript.caption
  current?.pendingOriginal = transcript.source.visible; current?.pendingTranslation = transcript.target.visible
  current?.updated = Date()
  if Date().timeIntervalSince(lastSave) > 2 { persist() }
  if object["finished"] as? Bool == true, running, !busy {
   let id = self.epoch
   Task { guard self.epoch == id else { return }; await self.stop() }
  }
 }
 @discardableResult
 func persist() -> Bool {
  guard let current, !current.isEmpty else { hasUnsavedHistory = false; return true }
  do {
   try saveHistory(current)
   hasUnsavedHistory = false; lastSave = Date()
  } catch {
   hasUnsavedHistory = true
   self.error = "历史记录保存失败，请重试保存后再退出或开始新会话。\n" + error.localizedDescription
   return false
  }
  do { history = try loadHistory() }
  catch { self.error = "历史列表读取失败。\n" + error.localizedDescription }
  return true
 }
 func connectEvents(_ socket: Soniox) {
  let id = epoch
  let (events, continuation) = AsyncStream<SessionEvent>.makeStream()
  eventContinuation = continuation
  eventTask = Task { @MainActor [weak self] in
   for await event in events {
    // Barriers must always resume, even after session invalidation.
    if case let .barrier(waiter) = event { waiter.resume(); continue }
    guard let self, self.epoch == id else { continue }
    switch event {
    case let .message(data): self.receive(data, epoch: id)
    case .reconnect:
     self.current?.append(self.transcript.finishFinals())
     self.transcript = Transcript()
    case let .firstAudio(date): self.timeline.firstAudio(at: date, sessionStart: self.began)
    case let .fatal(message):
     self.error = message
     if self.busy { self.startFailure = message }
     else { Task { guard self.epoch == id else { return }; await self.stop() } }
    case .barrier: break
    }
   }
  }
  socket.orderedEvent = { continuation.yield($0) }
 }
 func socketBarrier(_ socket: Soniox) async {
  await withCheckedContinuation { socket.barrier($0) }
 }
 func closeEvents() {
  eventContinuation?.finish(); eventContinuation = nil
  eventTask = nil
 }

 private func finalizeCurrent() {
  current?.append(transcript.finishFinals())
  current?.ended = Date(); current?.updated = Date()
  current?.pendingOriginal = transcript.source.partial
  current?.pendingTranslation = transcript.target.partial
 }
 @discardableResult
 func stop() async -> Bool {
  guard !busy else { return false }
  guard running || client != nil else { return persist() }
  busy = true; defer { busy = false }
  do { try await audio.stop() } catch { self.error = "停止音频采集失败。\n" + error.localizedDescription }
  if let client {
   await withCheckedContinuation { continuation in client.finish(timeout: 2) { _ in continuation.resume() } }
   await socketBarrier(client)
  }
  finalizeCurrent()
  let saved = persist()
  epoch = UUID(); client = nil; running = false; closeEvents()
  status = saved ? "已停止，历史已保存" : "已停止，历史尚未保存，请重试"
  return saved
 }
 func export(srt: Bool) {
  guard let entry = viewed else { return }
  do { try Archive.export(entry, mode: settings.display, srt: srt) }
  catch { self.error = error.localizedDescription }
 }
 func showPanel() {
  if panel == nil {
   let p = NSPanel(contentRect: NSRect(x: 120, y: 120, width: 760, height: 220),
    styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
   p.title = "LiveSubs"; p.level = .floating
   p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
   p.isFloatingPanel = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
   p.isMovableByWindowBackground = true; p.isOpaque = false; p.backgroundColor = .clear
   p.contentMinSize = NSSize(width: 360, height: 140)
   p.contentView = NSHostingView(rootView: FloatingCaptions(model: self))
   panel = p
  }
  panel?.orderFrontRegardless()
 }
}
