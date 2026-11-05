import Foundation
import Observation

/// App settings and the Soniox key. The key lives only in the Keychain;
/// settings (no secrets) are mirrored to the shared container for the extension.
@MainActor @Observable
final class SettingsStore {
 private static let defaultsKey = "LiveSubs.settings.v1"
 /// Views call persist() from onChange; no property observers under @Observable.
 var settings: AppSettings
 var keyDraft = ""
 var message = ""
 var testing = false
 var hasKey = false
 private var tester: Soniox?

 init() {
  settings = AppSettings.decode(UserDefaults.standard.data(forKey: Self.defaultsKey))
  hasKey = !Store.key().isEmpty
  keyDraft = ""
  Store.saveSharedSettings(settings)
 }
 func persist() {
  settings = settings.normalized()
  UserDefaults.standard.set(settings.encoded(), forKey: Self.defaultsKey)
  Store.saveSharedSettings(settings)
 }
 var storedKeyLength: Int { Store.key().count }
 private var trimmed: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

 private func saveMessage() -> String {
  let scope = Store.saveScopeDescription
  return "已保存（" + scope + "）" + (scope.hasPrefix("共享钥匙串") ? "" : "。广播扩展可能读不到，录屏前请检查诊断页")
 }
 func saveKey() {
  do {
   try Store.save(trimmed)
   hasKey = true; keyDraft = ""
   message = saveMessage()
  } catch {
   message = "保存失败 " + error.localizedDescription
  }
 }
 /// Connects with the saved key and sends one second of silence.
 func testKey() {
  if !trimmed.isEmpty {
   do { try Store.save(trimmed); hasKey = true; keyDraft = "" } catch { message = "保存失败 " + error.localizedDescription; return }
  }
  let key = Store.key()
  guard !key.isEmpty else { message = "请先填写 Soniox Key"; return }
  testing = true
  message = "连接 Soniox 并发送一秒静音…"
  let c = Soniox(); tester = c
  c.onStatus = { [weak self] s in Task { @MainActor in if self?.testing == true { self?.message = s } } }
  c.onFatal = { [weak self] e in
   Task { @MainActor in
    guard let self, self.testing else { return }
    self.message = "连接失败 " + e; self.finishTest()
   }
  }
  c.onMessage = { [weak self] obj in
   let code = (obj["error_code"] as? Int).map(String.init)
   let valid = obj["tokens"] is [[String: Any]] || obj["finished"] as? Bool == true
   Task { @MainActor in
    guard let self, self.testing else { return }
    if let code { self.message = "Soniox 返回错误，错误码 " + code; self.finishTest(); return }
    guard valid else { return }
    self.message = "已收到 Soniox 响应，连接可用"; self.finishTest()
   }
  }
  c.start(key, config: SonioxConfig.json(settings.languages))
  Task { @MainActor in
   try? await Task.sleep(for: .seconds(1))
   guard self.testing else { return }
   c.send(Data(repeating: 0, count: 32_000), voiced: false)
   try? await Task.sleep(for: .seconds(8))
   if self.testing { self.message = "未收到有效识别响应，请检查 Key、网络或余额"; self.finishTest() }
  }
 }
 private func finishTest() { testing = false; tester?.stop(); tester = nil }
}

/// Caption history kept inside the app (Application Support/History).
/// Sessions written by the extension are imported from the shared container;
/// deleting removes both copies and remembers the id so it is never re-imported.
@MainActor @Observable
final class HistoryStore {
 var entries: [HistoryEntry] = []
 var lastError = ""
 private static let deletedKey = "LiveSubs.history.deleted"
 private let fm = FileManager.default

 private var directory: URL? {
  guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
  let dir = base.appendingPathComponent("History", isDirectory: true)
  try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
 }
 private var deleted: Set<String> {
  get { Set(UserDefaults.standard.stringArray(forKey: Self.deletedKey) ?? []) }
  set { UserDefaults.standard.set(Array(newValue.suffix(2000)), forKey: Self.deletedKey) }
 }

 func refresh() {
  importShared()
  guard let dir = directory else { return }
  let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
  let gone = deleted
  entries = urls.filter { $0.pathExtension == "json" }
   .compactMap { try? Data(contentsOf: $0) }
   .compactMap(HistoryEntry.decode)
   .filter { !gone.contains($0.id) && !$0.isEmpty }
   .sorted { $0.started > $1.started }
 }

 private func importShared() {
  guard let shared = Store.sessionsDirectory, let dir = directory,
        let urls = try? fm.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil) else { return }
  let gone = deleted
  for url in urls where url.pathExtension == "json" {
   guard let data = try? Data(contentsOf: url), let entry = HistoryEntry.decode(data), !gone.contains(entry.id) else { continue }
   let target = dir.appendingPathComponent(entry.id + ".json")
   if let existing = (try? Data(contentsOf: target)).flatMap(HistoryEntry.decode), existing.updated >= entry.updated { continue }
   do { try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
   catch { lastError = "历史记录导入失败" }
  }
 }

 /// Writes an app-side record (同声传译, 转录) and refreshes the list.
 func save(_ entry: HistoryEntry) {
  guard let dir = directory, HistoryEntry.safeID(entry.id), let data = entry.encoded() else { return }
  do {
   try data.write(to: dir.appendingPathComponent(entry.id + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  } catch { lastError = "记录保存失败"; return }
  if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
  else if !entry.isEmpty { entries.insert(entry, at: 0) }
 }

 func delete(_ entry: HistoryEntry) {
  var gone = deleted; gone.insert(entry.id); deleted = gone
  if let dir = directory { try? fm.removeItem(at: dir.appendingPathComponent(entry.id + ".json")) }
  if let shared = Store.sessionsDirectory { try? fm.removeItem(at: shared.appendingPathComponent(entry.id + ".json")) }
  entries.removeAll { $0.id == entry.id }
  Diagnostics.record("history.deleted")
 }

 /// Writes an export file into the app's temporary directory for sharing.
 func exportFile(_ entry: HistoryEntry, mode: DisplayMode, srt: Bool) -> URL? {
  // 字幕-11月5日_10-02.txt, 同传-…, 转录-<file name>.srt (plan §5.2)
  let name = entry.exportBaseName + (srt ? ".srt" : ".txt")
  let url = fm.temporaryDirectory.appendingPathComponent(name)
  do {
   try (srt ? entry.srt(mode) : entry.plainText(mode)).write(to: url, atomically: true, encoding: .utf8)
   return url
  } catch { lastError = "导出失败"; return nil }
 }

 #if DEBUG
 /// UI-test fixture only (Debug builds with --ui-testing-seed-history).
 func seedForUITests() {
  guard let dir = directory else { return }
  var entry = HistoryEntry(id: "UITEST-0001", started: Date(timeIntervalSince1970: 1_800_000_000),
   updated: Date(timeIntervalSince1970: 1_800_000_100), source: "en", target: "zh")
  entry.append([
   Segment(lane: .original, text: "Hello everyone, welcome back.", start: 0, end: 1800, approximate: false),
   Segment(lane: .translation, text: "大家好，欢迎回来。", start: 2000, end: 2000, approximate: true),
   Segment(lane: .original, text: "Today we talk about rivers.", start: 2500, end: 4200, approximate: false),
   Segment(lane: .translation, text: "今天我们聊聊河流。", start: 4400, end: 4400, approximate: true)
  ])
  entry.ended = Date(timeIntervalSince1970: 1_800_000_100)
  var gone = deleted; gone.remove(entry.id); deleted = gone
  if let data = entry.encoded() { try? data.write(to: dir.appendingPathComponent(entry.id + ".json"), options: .atomic) }
 }
 #endif
}
