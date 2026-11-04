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
 private var offset = 0
 private var lastSave = Date.distantPast
 private var panel: NSPanel?
 private var startFailure: String?

 init() {
  do { keyDraft = try KeyVault.read(); history = try Archive.load() }
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
  busy = true; defer { busy = false }
  do {
   let key = try KeyVault.read()
   guard !key.isEmpty else { error = "请先保存 Soniox API Key"; return }
   startFailure = nil; epoch = UUID(); let id = epoch
   began = Date(); offset = 0; transcript = Transcript(); caption = Caption(); selectedHistory = nil
   let language = settings.languages.normalized()
   current = HistoryEntry(id: UUID().uuidString, started: began, updated: began, source: language.source, target: language.target)
   let socket = Soniox()
   socket.onMessage = { [weak self] object in
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    Task { @MainActor in self?.receive(data, epoch: id) }
   }
   socket.onStatus = { [weak self] message in Task { @MainActor in
    guard let self, self.epoch == id else { return }; self.status = message
   }}
   socket.onFatal = { [weak self] message in Task { @MainActor in
    guard let self, self.epoch == id else { return }; self.error = message
    if self.busy { self.startFailure = message; return }
    await self.stop(); self.status = message
   }}
   socket.onReconnect = { [weak self] in Task { @MainActor in
    guard let self, self.epoch == id else { return }
    self.current?.append(self.transcript.finishFinals())
    self.transcript = Transcript(); self.offset = Int(Date().timeIntervalSince(self.began) * 1000)
   }}
   client = socket; status = "请求系统音频权限…"
   socket.start(key, config: SonioxConfig.json(language))
   try await audio.start(client: socket) { [weak self] message in Task { @MainActor in
    guard let self, self.epoch == id else { return }; self.error = message
    if self.busy { self.startFailure = message; return }
    await self.stop(); self.status = message
   }}
   if let startFailure {
    try await audio.stop(); socket.stop(); client = nil
    status = startFailure; error = startFailure; return
   }
   running = true; status = "正在聆听系统音频"
   if !split { showPanel() }
  } catch {
   client?.stop(); client = nil
   self.error = "无法开始采集。请在系统设置的屏幕与系统音频录制中允许 LiveSubs，必要时重新打开 App。\n" + error.localizedDescription
   status = "采集未启动"
  }
 }
 private func receive(_ data: Data, epoch: UUID) {
  guard self.epoch == epoch, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
  var tokens = object["tokens"] as? [[String: Any]] ?? []
  for i in tokens.indices {
   if let start = tokens[i]["start_ms"] as? Int { tokens[i]["start_ms"] = start + offset }
   if let end = tokens[i]["end_ms"] as? Int { tokens[i]["end_ms"] = end + offset }
  }
  let segments = transcript.ingest(tokens, arrivalMS: Int(Date().timeIntervalSince(began) * 1000))
  current?.append(segments); caption = transcript.caption
  current?.pendingOriginal = transcript.source.visible; current?.pendingTranslation = transcript.target.visible
  current?.updated = Date()
  if Date().timeIntervalSince(lastSave) > 2 { persist() }
  if object["finished"] as? Bool == true, running, !busy {
   Task { await stop() }
  }
 }
 private func persist() {
  guard let current, !current.isEmpty else { return }
  do { try Archive.save(current); lastSave = Date(); history = try Archive.load() }
  catch { self.error = "历史记录保存失败。\n" + error.localizedDescription }
 }
 func stop() async {
  guard !busy else { return }
  busy = true; defer { busy = false }
  do { try await audio.stop() } catch { self.error = "停止音频采集失败。\n" + error.localizedDescription }
  if let client {
   await withCheckedContinuation { continuation in client.finish(timeout: 2) { _ in continuation.resume() } }
  }
  current?.append(transcript.finishFinals())
  current?.ended = Date(); current?.updated = Date()
  current?.pendingOriginal = transcript.source.partial; current?.pendingTranslation = transcript.target.partial
  persist(); epoch = UUID(); client = nil; running = false; status = "已停止，历史已保存"
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
