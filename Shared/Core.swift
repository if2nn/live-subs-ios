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
 static func read() -> Caption? {
  guard let root = root, let data = try? Data(contentsOf: root.appendingPathComponent("caption.json")) else { return nil }
  return try? JSONDecoder().decode(Caption.self, from: data)
 }
}
