import Foundation
import Security

enum Store {
 static var root: URL? { SharedSigning.resolved?.root }
 static func query() throws -> [String: Any] {
  guard let group = SharedSigning.resolved?.group else {
   throw NSError(domain: "LiveSubs", code: 1, userInfo: [NSLocalizedDescriptionKey: "共享组不可用，请检查主 App 与广播扩展的重签权限"])
  }
  // An authorized App Group is also a Keychain access group (Apple public API).
  return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "LiveSubs",
          kSecAttrAccount as String: "Soniox", kSecAttrAccessGroup as String: group]
 }
 static func key() -> String {
  guard var q = try? query() else { return "" }
  q[kSecReturnData as String] = true
  var result: CFTypeRef?
  guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data else { return "" }
  return String(decoding: data, as: UTF8.self)
 }
 static func save(_ key: String) throws {
  guard !key.isEmpty else {
   throw NSError(domain: "LiveSubs", code: 2, userInfo: [NSLocalizedDescriptionKey: "API Key 不能为空"])
  }
  let q = try query()
  let update: [String: Any] = [kSecValueData as String: Data(key.utf8),
   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
  var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
  if status == errSecItemNotFound {
   let add = q.merging(update) { _, value in value }
   status = SecItemAdd(add as CFDictionary, nil)
   if status == errSecDuplicateItem { status = SecItemUpdate(q as CFDictionary, update as CFDictionary) }
  }
  if status != errSecSuccess {
   let reason = SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串操作失败"
   throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
    userInfo: [NSLocalizedDescriptionKey: "\(reason) (\(status))，请检查共享组签名"])
  }
 }
 static func publish(_ c: Caption) {
  guard let root = root, let data = try? JSONEncoder().encode(c) else { return }
  try? data.write(to: root.appendingPathComponent("caption.json"), options: .atomic)
 }
 static func read() -> Caption? {
  guard let root = root, let data = try? Data(contentsOf: root.appendingPathComponent("caption.json")) else { return nil }
  return try? JSONDecoder().decode(Caption.self, from: data)
 }
}
