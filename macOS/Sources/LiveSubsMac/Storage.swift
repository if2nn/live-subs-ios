import Foundation
import Security
import AppKit
import UniformTypeIdentifiers

enum KeyVault {
 static let service = "com.aian.livesubs.mac.soniox"
 static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: service, kSecAttrAccount as String: "api-key"] }
 static func read() throws -> String {
  var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
  var result: CFTypeRef?
  let status = SecItemCopyMatching(q as CFDictionary, &result)
  if status == errSecItemNotFound { return "" }
  guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8)
   else { throw VaultError.status(status) }
  return key
 }
 static func save(_ key: String) throws {
  let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
  if key.isEmpty {
   let status = SecItemDelete(query as CFDictionary)
   guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.status(status) }
   return
  }
  let attributes = [kSecValueData as String: Data(key.utf8)]
  var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  if status == errSecItemNotFound {
   var q = query; q[kSecValueData as String] = Data(key.utf8)
   q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
   status = SecItemAdd(q as CFDictionary, nil)
  }
  guard status == errSecSuccess else { throw VaultError.status(status) }
 }
 enum VaultError: LocalizedError {
  case status(OSStatus)
  var errorDescription: String? {
   if case let .status(code) = self { return "钥匙串操作失败（\(code)）" }; return nil
  }
 }
}
@MainActor
enum Archive {
 static var folder: URL {
  FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
   .appendingPathComponent("LiveSubsMac/History", isDirectory: true)
 }
 static func save(_ entry: HistoryEntry) throws {
  guard HistoryEntry.safeID(entry.id), let data = entry.encoded() else { throw CocoaError(.fileWriteInvalidFileName) }
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try data.write(to: folder.appendingPathComponent(entry.id + ".json"), options: [.atomic])
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent(entry.id + ".json").path)
 }
 static func load() throws -> [HistoryEntry] {
  guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
  return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
   .filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) }
   .compactMap(HistoryEntry.decode).sorted { $0.started > $1.started }
 }
 static func export(_ entry: HistoryEntry, mode: DisplayMode, srt: Bool) throws {
  let panel = NSSavePanel()
  panel.nameFieldStringValue = "LiveSubs-" + entry.id + (srt ? ".srt" : ".txt")
  panel.allowedContentTypes = srt ? [.data] : [.plainText]
  guard panel.runModal() == .OK, let url = panel.url else { return }
  var text = srt ? entry.srt(mode) : entry.plainText(mode)
  if !srt {
   let pending = [entry.pendingOriginal, entry.pendingTranslation].filter { !$0.isEmpty }.joined(separator: "\n")
   if !pending.isEmpty { text += "\n\n[未定稿]\n" + pending }
  }
  try text.write(to: url, atomically: true, encoding: .utf8)
 }
}
