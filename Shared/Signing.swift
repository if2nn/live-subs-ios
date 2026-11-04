import Foundation
import Security

enum SharedSigning {
 static let baseGroup = "group.com.aian.livesubs"
 struct Probe: Sendable {
  let group: String
  let container: URL?
  let status: OSStatus
 }
 struct Discovery: Sendable {
  let profilePresent: Bool
  let profileParsed: Bool
  let defaultGroup: String?
  let defaultStatus: OSStatus
  let privateGroup: String?
  let probes: [Probe]
  let keychain: [(String, OSStatus)]
 }
 static func profileEntitlements() -> [String: Any] {
  guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 2_097_152, let data = try? Data(contentsOf: url) else { return [:] }
  return ProfileHints.decode(data)
 }
 static func defaultProbe() -> (String?, OSStatus) {
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
  let status = SecItemAdd(query as CFDictionary, &result)
  guard status == errSecSuccess else { return (nil, status) }
  let group = (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
  var removal: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: "LiveSubs.SigningProbe", kSecAttrAccount as String: account]
  if let group = group { removal[kSecAttrAccessGroup as String] = group }
  SecItemDelete(removal as CFDictionary)
  return (group, status)
 }
 static func keychainStatus(_ group: String) -> OSStatus {
  let account = UUID().uuidString
  let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: "LiveSubs.SharedProbe", kSecAttrAccount as String: account,
   kSecAttrAccessGroup as String: group, kSecValueData as String: Data(),
   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
  let status = SecItemAdd(q as CFDictionary, nil)
  guard status == errSecSuccess else { return status }
  var removal = q
  removal.removeValue(forKey: kSecValueData as String)
  removal.removeValue(forKey: kSecAttrAccessible as String)
  SecItemDelete(removal as CFDictionary)
  return status
 }
 static let discovery: Discovery = {
  let profile = profileEntitlements()
  let configured = Bundle.main.object(forInfoDictionaryKey: "SharedAppGroupCandidates") as? [String] ?? []
  let (defaultGroup, defaultStatus) = defaultProbe()
  let prefix = defaultGroup?.split(separator: ".").first.map(String.init)
  let candidates = ProfileHints.candidates(profile: profile, configured: configured,
   bundleID: Bundle.main.bundleIdentifier ?? "", prefix: prefix)
  let probes = candidates.map { candidate in
   Probe(group: candidate,
    container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate),
    status: keychainStatus(candidate))
  }
  let appID = profile["application-identifier"] as? String
  // A dedicated app identifier is private even if SideStore made a different
  // shared group the default. Never guess a private identifier without probing.
  let profilePrivateID = appID.flatMap { ProfileHints.identifiers([$0]).first }
  let derivedPrivateID: String? = {
   guard defaultStatus == errSecSuccess, let prefix = prefix,
         let bundleID = Bundle.main.bundleIdentifier else { return nil }
   return ProfileHints.identifiers([prefix + "." + bundleID]).first
  }()
  let privateIDs = [profilePrivateID, derivedPrivateID].compactMap { $0 }
  let privateGroup = privateIDs.first { keychainStatus($0) == errSecSuccess }
  let extra = ProfileHints.identifiers(profile["keychain-access-groups"]).sorted()
   .filter { $0 != appID && !candidates.contains($0) }
   .map { ($0, keychainStatus($0)) }
  return Discovery(profilePresent: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil,
   profileParsed: !profile.isEmpty, defaultGroup: defaultGroup, defaultStatus: defaultStatus,
   privateGroup: privateGroup, probes: probes, keychain: extra)
 }()
 // Container access and Keychain access are independent. Do not discard a
 // real container merely because the signer omitted shared Keychain rights.
 static var resolved: (group: String, root: URL)? {
  guard let p = discovery.probes.first(where: { $0.container != nil }), let root = p.container else { return nil }
  return (p.group, root)
 }
 static var keychainGroups: [String] {
  // Do not publish credentials into unrelated signer/SideStore access groups.
  // Profile Keychain groups are shown as diagnostics only; App Groups are
  // shared candidates for this app and must pass an actual Keychain probe.
  discovery.probes.filter { $0.status == errSecSuccess }.map(\.group)
 }
 static var isExtension: Bool { Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil }
 static var diagnosticText: String {
  let d = discovery
  var lines = [
   "Bundle ID: " + (Bundle.main.bundleIdentifier ?? "(missing)"),
   "Process: " + (isExtension ? "broadcast extension" : "main app"),
   "Profile present: \(d.profilePresent), parsed: \(d.profileParsed)",
   "Profile values are hints; OS probes authorize access.",
   "Default access group: " + (d.defaultGroup ?? "(unknown)") + " OSStatus=\(d.defaultStatus)",
   "Private app access group: " + (d.privateGroup ?? "(unconfirmed; default Keychain fallback)"),
   "Available container: " + (resolved?.group ?? "(none)"),
   "Available shared Keychain groups: " + (keychainGroups.isEmpty ? "(none)" : keychainGroups.joined(separator: ", "))
  ]
  lines += d.probes.map { "Candidate \($0.group) container=\($0.container != nil) Keychain OSStatus=\($0.status)" }
  lines += d.keychain.map { "Profile access group \($0.0) Keychain OSStatus=\($0.1)" }
  lines.append("Extension sharing is not confirmed until the extension reads the saved credential.")
  return lines.joined(separator: "\n")
 }
 static var broadcastIdentifier: String? {
  guard let plugins = Bundle.main.builtInPlugInsURL,
        let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
  return urls.compactMap { Bundle(url: $0) }.first {
   let ext = $0.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
   return ext?["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload"
  }?.bundleIdentifier
 }
}
