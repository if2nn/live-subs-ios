import Foundation

/// Pure, Codable settings shared by the app (UI) and the broadcast extension
/// (only the language part matters there). Foundation only.
struct Language: Hashable, Sendable, Identifiable {
 let code: String
 let name: String
 var id: String { code }
 static let auto = Language(code: "auto", name: "自动识别")
 /// Soniox supported-language codes we expose. Kept short on purpose.
 static let all: [Language] = [
  Language(code: "zh", name: "中文"), Language(code: "en", name: "英语"),
  Language(code: "ja", name: "日语"), Language(code: "ko", name: "韩语"),
  Language(code: "es", name: "西班牙语"), Language(code: "fr", name: "法语"),
  Language(code: "de", name: "德语"), Language(code: "ru", name: "俄语"),
  Language(code: "pt", name: "葡萄牙语"), Language(code: "it", name: "意大利语"),
  Language(code: "ar", name: "阿拉伯语"), Language(code: "hi", name: "印地语"),
  Language(code: "th", name: "泰语"), Language(code: "vi", name: "越南语"),
  Language(code: "id", name: "印尼语")
 ]
 static let sources: [Language] = [auto] + all
 static func name(_ code: String) -> String {
  sources.first { $0.code == code }?.name ?? code
 }
}

enum DisplayMode: String, Codable, Sendable, CaseIterable, Identifiable {
 case bilingual, translationOnly, originalOnly
 var id: String { rawValue }
 var title: String {
  switch self { case .bilingual: "双语"; case .translationOnly: "仅译文"; case .originalOnly: "仅原文" }
 }
}

/// App appearance. `system` follows the device setting (preview 6 default);
/// preview 5 and earlier forced dark. The SwiftUI ColorScheme mapping lives in
/// the app target so this file stays Foundation-only for the extension.
enum AppearanceMode: String, Codable, Sendable, CaseIterable, Identifiable {
 case system, light, dark
 var id: String { rawValue }
 var title: String {
  switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
 }
}

/// Shape of the PiP caption window. `classic` is the preview 4 shape (height
/// follows font and line count) and stays the default; `strip` is the optional
/// wide, flat 3:1 subtitle bar added in preview 5.
enum PiPShape: String, Codable, Sendable, CaseIterable, Identifiable {
 case classic, strip
 var id: String { rawValue }
 var title: String {
  switch self { case .classic: "经典"; case .strip: "长条" }
 }
}

enum CaptionColor: String, Codable, Sendable, CaseIterable, Identifiable {
 case white, yellow, cyan, green, gray
 var id: String { rawValue }
 var title: String {
  switch self { case .white: "白"; case .yellow: "黄"; case .cyan: "青"; case .green: "绿"; case .gray: "灰" }
 }
 /// sRGB components 0...1
 var rgb: (Double, Double, Double) {
  switch self {
  case .white: (1, 1, 1)
  case .yellow: (1, 0.86, 0.2)
  case .cyan: (0.45, 0.9, 1)
  case .green: (0.55, 0.95, 0.55)
  case .gray: (0.72, 0.72, 0.74)
  }
 }
}

enum CaptionPosition: String, Codable, Sendable, CaseIterable, Identifiable {
 case top, center, bottom
 var id: String { rawValue }
 var title: String {
  switch self { case .top: "顶部"; case .center: "居中"; case .bottom: "底部" }
 }
}

struct SubtitleStyle: Codable, Sendable, Equatable {
 var fontSize: Double = 30          // points at the 1280-wide PiP canvas scale /2
 var translationColor: CaptionColor = .white
 var originalColor: CaptionColor = .gray
 var backgroundOpacity: Double = 1.0 // PiP canvas itself is always black
 var lines: Int = 2                  // lines per lane
 var translationFirst: Bool = false  // false: original on top
 var position: CaptionPosition = .bottom

 static let fontRange: ClosedRange<Double> = 18...48
 static let lineRange: ClosedRange<Int> = 1...4
 static let opacityRange: ClosedRange<Double> = 0.3...1.0
 /// Clamps a decoded or user-provided style into supported bounds.
 func normalized() -> SubtitleStyle {
  var s = self
  s.fontSize = min(max(fontSize.isFinite ? fontSize : 30, Self.fontRange.lowerBound), Self.fontRange.upperBound)
  s.lines = min(max(lines, Self.lineRange.lowerBound), Self.lineRange.upperBound)
  s.backgroundOpacity = min(max(backgroundOpacity.isFinite ? backgroundOpacity : 1, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
  return s
 }
}

struct LanguageSettings: Codable, Sendable, Equatable {
 var source: String = "auto"
 var target: String = "zh"
 func normalized() -> LanguageSettings {
  var l = self
  if !Language.sources.contains(where: { $0.code == source }) { l.source = "auto" }
  if !Language.all.contains(where: { $0.code == target }) { l.target = "zh" }
  return l
 }
 /// No translation is requested when the fixed source already equals the target.
 var translates: Bool { source == "auto" || source != target }
}

struct AppSettings: Codable, Sendable, Equatable {
 var languages = LanguageSettings()
 var display: DisplayMode = .bilingual
 var style = SubtitleStyle()
 var pipShape: PiPShape = .classic
 var appearance: AppearanceMode = .system
 init() {}
 // Missing keys (settings saved by preview 4 and earlier) keep their defaults
 // instead of resetting everything the user chose.
 private enum CodingKeys: String, CodingKey { case languages, display, style, pipShape, appearance }
 init(from decoder: Decoder) throws {
  let c = try decoder.container(keyedBy: CodingKeys.self)
  languages = (try? c.decodeIfPresent(LanguageSettings.self, forKey: .languages)) ?? LanguageSettings()
  display = (try? c.decodeIfPresent(DisplayMode.self, forKey: .display)) ?? .bilingual
  style = (try? c.decodeIfPresent(SubtitleStyle.self, forKey: .style)) ?? SubtitleStyle()
  pipShape = (try? c.decodeIfPresent(PiPShape.self, forKey: .pipShape)) ?? .classic
  appearance = (try? c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)) ?? .system
 }
 func normalized() -> AppSettings {
  var s = self
  s.languages = languages.normalized(); s.style = style.normalized()
  return s
 }
 static func decode(_ data: Data?) -> AppSettings {
  guard let data, data.count < 16_384,
        let value = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
  return value.normalized()
 }
 func encoded() -> Data { (try? JSONEncoder().encode(normalized())) ?? Data() }
}

/// Builds the Soniox start request (no key: the key travels only in the
/// Authorization header). Returned as JSON text so it is Sendable.
enum SonioxConfig {
 static let model = "stt-rt-v6"
 static func dictionary(_ languages: LanguageSettings) -> [String: Any] {
  let l = languages.normalized()
  var hints: [String]
  if l.source == "auto" {
   // Hints only bias recognition; detection still covers other languages.
   hints = [l.target, "en", "zh", "ja"]
  } else {
   hints = [l.source]
  }
  var seen = Set<String>(); hints = hints.filter { seen.insert($0).inserted }
  var config: [String: Any] = [
   "model": model,
   "audio_format": "s16le",
   "sample_rate": 16_000,
   "num_channels": 1,
   "language_hints": hints,
   "enable_language_identification": true,
   "enable_endpoint_detection": true
  ]
  if l.translates {
   config["translation"] = ["type": "one_way", "target_language": l.target]
  }
  return config
 }
 static func json(_ languages: LanguageSettings) -> String {
  let data = (try? JSONSerialization.data(withJSONObject: dictionary(languages), options: [.sortedKeys])) ?? Data()
  return String(decoding: data, as: UTF8.self)
 }
}
