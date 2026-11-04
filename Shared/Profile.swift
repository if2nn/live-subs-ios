import Foundation

// Reads a bounded XML payload as discovery hints, NOT a CMS signature verifier.
// Every hint still requires a sandbox/Keychain operation approved by iOS.
// No external entities, wildcard groups, file paths, or unbounded collections.
enum ProfileHints {
 static func decode(_ data: Data) -> [String: Any] {
  guard data.count <= 2_097_152,
        let begin = data.range(of: Data("<?xml".utf8)),
        let end = data.range(of: Data("</plist>".utf8), in: begin.lowerBound..<data.endIndex),
        data.range(of: Data("<?xml".utf8), in: begin.upperBound..<data.endIndex) == nil else { return [:] }
  let payload = data.subdata(in: begin.lowerBound..<end.upperBound)
  let standardDTD = Data("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">".utf8)
  var inspected = payload
  if let dtd = inspected.range(of: standardDTD) { inspected.removeSubrange(dtd) }
  guard inspected.range(of: Data("<!DOCTYPE".utf8)) == nil,
        payload.range(of: Data("<!ENTITY".utf8)) == nil,
        let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any],
        let entitlements = plist["Entitlements"] as? [String: Any] else { return [:] }
  return entitlements
 }
 static func identifiers(_ value: Any?) -> [String] {
  guard let strings = value as? [String], strings.count <= 64 else { return [] }
  return strings.filter { !$0.isEmpty && $0.utf8.count <= 255 &&
   $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) } }
 }
 static func candidates(profile: [String: Any], configured: [String], bundleID: String, prefix: String?) -> [String] {
  let base = "group.com.aian.livesubs"
  let parent = bundleID.hasSuffix(".broadcast") ? String(bundleID.dropLast(".broadcast".count)) : bundleID
  var values = identifiers(profile["com.apple.security.application-groups"]).sorted()
  values += identifiers(configured) + ["group." + parent]
  if let prefix = prefix, identifiers([prefix]).count == 1 {
   values += [base + "." + prefix, prefix + "." + base]
  }
  values.append(base)
  var seen = Set<String>()
  return values.filter { seen.insert($0).inserted }
 }
}
