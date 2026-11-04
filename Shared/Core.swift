import Foundation
import Security

enum Store {
 static var root: URL? { SharedSigning.resolved?.root }
 private static func query(group: String?, local: Bool = false) -> [String: Any] {
  var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: local ? "LiveSubs.Private" : "LiveSubs",
   kSecAttrAccount as String: "Soniox"]
  if let group = group { q[kSecAttrAccessGroup as String] = group }
  return q
 }
 private static func read(_ query: [String: Any]) -> String {
  var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
  var result: CFTypeRef?
  guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
  return String(decoding: data, as: UTF8.self)
 }
 private static func write(_ key: String, query q: [String: Any]) -> OSStatus {
  let update: [String: Any] = [kSecValueData as String: Data(key.utf8),
   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
  var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
  if status == errSecItemNotFound {
   status = SecItemAdd(q.merging(update) { _, value in value } as CFDictionary, nil)
   if status == errSecDuplicateItem { status = SecItemUpdate(q as CFDictionary, update as CFDictionary) }
  }
  return status
 }
 // Credential is returned only to the caller, never serialized in IPC.
 struct KeyReadResult {
  let value: String
  let status: OSStatus
  var success: Bool { status == errSecSuccess && !value.isEmpty }
 }
 static func keyReadResult() -> KeyReadResult {
  var candidates: [[String:Any]] = []
  if !SharedSigning.isExtension {
   candidates.append(query(group:SharedSigning.discovery.privateGroup ?? SharedSigning.discovery.defaultGroup,local:true))
  }
  candidates += SharedSigning.keychainGroups.map { query(group:$0) }
  var last: OSStatus = SharedSigning.discovery.probes.first?.status ?? errSecItemNotFound
  for var q in candidates {
   q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
   var result: CFTypeRef?
   let status=SecItemCopyMatching(q as CFDictionary,&result)
   last=status
   if status == errSecSuccess, let data=result as? Data {
    let value=String(decoding:data,as:UTF8.self)
    if !value.isEmpty { return KeyReadResult(value:value,status:status) }
   }
  }
  return KeyReadResult(value:"",status:last)
 }
 static func key() -> String {
  // The app's newest saved key wins even if a shared write previously failed.
  if !SharedSigning.isExtension {
   let local = read(query(group: SharedSigning.discovery.privateGroup ?? SharedSigning.discovery.defaultGroup, local: true))
   if !local.isEmpty { return local }
  }
  for group in SharedSigning.keychainGroups {
   let shared = read(query(group: group))
   if !shared.isEmpty { return shared }
  }
  return ""
 }
 static var saveScopeDescription: String {
  let local = key()
  if !local.isEmpty, SharedSigning.keychainGroups.contains(where: { read(query(group: $0)) == local }) {
   return "共享钥匙串；扩展仍需启动验证"
  }
  return SharedSigning.discovery.privateGroup != nil
   ? "主 App 私有钥匙串"
   : "默认钥匙串；未确认私有或扩展共享"
 }
 static func save(_ raw: String) throws {
  let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !key.isEmpty else { throw NSError(domain: "LiveSubs", code: 2, userInfo: [NSLocalizedDescriptionKey: "API Key 不能为空"]) }
  guard !SharedSigning.isExtension else { throw NSError(domain: "LiveSubs", code: 3, userInfo: [NSLocalizedDescriptionKey: "请在主 App 保存 Key"]) }
  let privateQuery = query(group: SharedSigning.discovery.privateGroup ?? SharedSigning.discovery.defaultGroup, local: true)
  let localStatus = write(key, query: privateQuery)
  var sharedSaved = false
  for group in SharedSigning.keychainGroups {
   if write(key, query: query(group: group)) == errSecSuccess { sharedSaved = true }
  }
  guard localStatus == errSecSuccess || sharedSaved else {
   throw NSError(domain: NSOSStatusErrorDomain, code: Int(localStatus),
    userInfo: [NSLocalizedDescriptionKey: "钥匙串保存失败 OSStatus=\(localStatus)"])
  }
 }
 static func publish(_ c: Caption) {
  guard let root = root, let data = try? JSONEncoder().encode(c) else { return }
  try? data.write(to: root.appendingPathComponent("caption.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
 }
 /// Settings mirrored into the shared container so the extension can read the
 /// languages chosen in the app. Contains no credential.
 static func saveSharedSettings(_ settings: AppSettings) {
  guard let root = root else { return }
  let url = root.appendingPathComponent("Config/settings.json")
  try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try? settings.encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
 }
 static func sharedSettings() -> AppSettings {
  guard let root = root else { return AppSettings() }
  return AppSettings.decode(try? Data(contentsOf: root.appendingPathComponent("Config/settings.json")))
 }
 static var sessionsDirectory: URL? { root?.appendingPathComponent("Sessions", isDirectory: true) }
 static func writeHistory(_ entry: HistoryEntry) -> Bool {
  guard let dir = sessionsDirectory, HistoryEntry.safeID(entry.id), let data = entry.encoded() else { return false }
  do {
   try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
   try data.write(to: dir.appendingPathComponent(entry.id + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
   return true
  } catch { return false }
 }
 static func read() -> Caption? {
  guard let root = root, let data = try? Data(contentsOf: root.appendingPathComponent("caption.json")) else { return nil }
  return try? JSONDecoder().decode(Caption.self, from: data)
 }
}
