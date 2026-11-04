import Foundation

/// One captioning session, written by the extension into the shared container
/// and imported into the app's own History store. Contains caption text only:
/// never the API key, audio, or raw server responses.
struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
 struct Line: Codable, Sendable, Equatable {
  var lane: Segment.Lane
  var text: String
  var startMS: Int
  var endMS: Int
  var approximate: Bool
 }
 var schema = 1
 var id: String
 var started: Date
 var updated: Date
 var ended: Date?
 var source: String
 var target: String
 var lines: [Line] = []
 /// Uncertain partial text at the time of the last write (not final).
 var pendingOriginal = ""
 var pendingTranslation = ""

 static let maximumLines = 20_000

 var title: String {
  let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
  return f.string(from: started)
 }
 var durationMS: Int { lines.map(\.endMS).max() ?? 0 }
 var preview: String {
  let t = lines.last { $0.lane == .translation }?.text ?? lines.last?.text ?? ""
  return String(t.prefix(60))
 }
 var isEmpty: Bool { lines.isEmpty && pendingOriginal.isEmpty && pendingTranslation.isEmpty }

 mutating func append(_ segments: [Segment]) {
  for s in segments where !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
   lines.append(Line(lane: s.lane, text: s.text.trimmingCharacters(in: .whitespacesAndNewlines),
                     startMS: max(0, s.start), endMS: max(s.start, s.end), approximate: s.approximate))
  }
  if lines.count > Self.maximumLines { lines.removeFirst(lines.count - Self.maximumLines) }
 }

 /// Pairs each original line with the translation lines that arrived before the
 /// next original line. Soniox does not align them 1:1; this is display order.
 struct Row: Sendable, Equatable, Identifiable {
  var id: Int
  var startMS: Int
  var original: String
  var translation: String
 }
 var rows: [Row] {
  var rows: [Row] = []
  for line in lines {
   if line.lane == .original {
    rows.append(Row(id: rows.count, startMS: line.startMS, original: line.text, translation: ""))
   } else if let last = rows.indices.last {
    rows[last].translation += HistoryEntry.joiner(rows[last].translation, line.text) + line.text
   } else {
    rows.append(Row(id: rows.count, startMS: line.startMS, original: "", translation: line.text))
   }
  }
  return rows
 }
 static func joiner(_ a: String, _ b: String) -> String { HistoryEntryJoin.separator(a, b) }

 func plainText(_ mode: DisplayMode) -> String {
  rows.map { row in
   let stamp = "[" + HistoryEntry.clock(row.startMS) + "]"
   switch mode {
   case .originalOnly: return row.original.isEmpty ? nil : stamp + " " + row.original
   case .translationOnly: return row.translation.isEmpty ? nil : stamp + " " + row.translation
   case .bilingual:
    let body = [row.original, row.translation].filter { !$0.isEmpty }.joined(separator: "\n")
    return body.isEmpty ? nil : stamp + "\n" + body
   }
  }.compactMap { $0 }.joined(separator: "\n\n")
 }
 /// SRT with original timing; translation shares its original's cue.
 func srt(_ mode: DisplayMode) -> String {
  var out = ""; var index = 0
  let rs = rows
  for (i, row) in rs.enumerated() {
   let body: String
   switch mode {
   case .originalOnly: body = row.original
   case .translationOnly: body = row.translation
   case .bilingual: body = [row.original, row.translation].filter { !$0.isEmpty }.joined(separator: "\n")
   }
   guard !body.isEmpty else { continue }
   index += 1
   let start = row.startMS
   let next = i + 1 < rs.count ? rs[i + 1].startMS : start + 4000
   let end = max(start + 800, min(next, start + 8000))
   out += "\(index)\n\(SRT.time(start)) --> \(SRT.time(end))\n\(body)\n\n"
  }
  return out
 }
 static func clock(_ ms: Int) -> String {
  let s = max(0, ms) / 1000
  return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                   : String(format: "%02d:%02d", s / 60, s % 60)
 }
 static func safeID(_ id: String) -> Bool {
  !id.isEmpty && id.count <= 64 && id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
 }
 static func decode(_ data: Data) -> HistoryEntry? {
  guard data.count <= 8_000_000, let e = try? JSONDecoder.history.decode(HistoryEntry.self, from: data),
        e.schema == 1, safeID(e.id), e.lines.count <= maximumLines else { return nil }
  return e
 }
 func encoded() -> Data? { try? JSONEncoder.history.encode(self) }
}

extension JSONEncoder {
 static var history: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
 static var history: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
