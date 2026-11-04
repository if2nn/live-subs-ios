import Foundation
import Security

enum SharedSigning {
 static let baseGroup = "group.com.aian.livesubs"
 // Provisioning profile values are hints, never authorization. Validate the
 // actual sandbox container and Keychain operation instead of private APIs.
 static func profileEntitlements() -> [String: Any] {
  guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
        let data = try? Data(contentsOf: url),
        let begin = data.range(of: Data("<?xml".utf8)),
        let finish = data.range(of: Data("</plist>".utf8), in: begin.lowerBound..<data.endIndex),
        let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: begin.lowerBound..<finish.upperBound), options: [], format: nil) as? [String: Any]
  else { return [:] }
  return plist["Entitlements"] as? [String: Any] ?? [:]
 }
 static func defaultAccessGroup() -> String? {
  let account = UUID().uuidString
  let query: [String: Any] = [
   kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: "LiveSubs.SigningProbe",
   kSecAttrAccount as String: account,
   kSecValueData as String: Data(),
   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
   kSecReturnAttributes as String: true
  ]
  var result: CFTypeRef?
  guard SecItemAdd(query as CFDictionary, &result) == errSecSuccess else { return nil }
  let removal: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: "LiveSubs.SigningProbe", kSecAttrAccount as String: account]
  SecItemDelete(removal as CFDictionary)
  return (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
 }
 static let resolved: (group: String, root: URL)? = {
  let profile = profileEntitlements()
  let configured = Bundle.main.object(forInfoDictionaryKey: "SharedAppGroupCandidates") as? [String] ?? []
  let profiled = (profile["com.apple.security.application-groups"] as? [String] ?? [])
   .filter { $0 == baseGroup || $0.hasPrefix(baseGroup + ".") }
  let prefix = defaultAccessGroup()?.split(separator: ".").first.map(String.init)
  var candidates = configured + profiled
  if let prefix = prefix { candidates.append(baseGroup + "." + prefix) }
  candidates.append(baseGroup)
  var seen = Set<String>()
  for candidate in candidates where !candidate.contains("$(") && seen.insert(candidate).inserted {
   if let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) {
    return (candidate, root)
   }
  }
  return nil
 }()
 static var broadcastIdentifier: String? {
  guard let plugins = Bundle.main.builtInPlugInsURL,
        let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
  return urls.compactMap { Bundle(url: $0) }.first {
   let ext = $0.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
   return ext?["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload"
  }?.bundleIdentifier
 }
}
