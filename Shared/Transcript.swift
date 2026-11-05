import Foundation

struct Caption: Codable, Sendable, Equatable {
 var original = ""; var translated = ""; var status = "等待广播"; var updated = Date()
 /// Monotonic per extension session; lets the app skip unchanged frames.
 var seq = 0
 var session = ""
 /// The sentence being spoken now (or the last finished one); everything
 /// before it in `original`/`translated` is context drawn dimmer, lyric-style.
 var originalLive: String? = nil
 var translatedLive: String? = nil
}
struct Segment: Codable, Sendable {
 enum Lane: String, Codable, Sendable { case original, translation }
 var lane: Lane
 var text: String
 var start: Int
 var end: Int
 var approximate: Bool
}
struct Transcript: Codable, Sendable {
 struct Lane: Codable, Sendable {
  var final = ""; var partial = ""; var start: Int?; var end = 0
  var visible: String { final + partial }
 }
 var source = Lane()
 var target = Lane()
 var recentSource = ""
 var recentTarget = ""
 var lastSource = ""
 var lastTarget = ""
 // Each lane owns its boundary. Translation tokens have no source timestamps.
 mutating func ingest(_ tokens: [[String: Any]], arrivalMS: Int = 0) -> [Segment] {
  source.partial = ""; target.partial = ""
  var segments: [Segment] = []
  for token in tokens {
   guard let text = token["text"] as? String else { continue }
   let translated = token["translation_status"] as? String == "translation"
   let lane: Segment.Lane = translated ? .translation : .original
   if text == "<end>" || text == "<fin>" {
    if token["is_final"] as? Bool == true, let cue = close(lane) { segments.append(cue) }
    continue
   }
   let final = token["is_final"] as? Bool == true
   if translated {
    if target.start == nil { target.start = max(0, arrivalMS) }
    target.end = max(target.end, arrivalMS)
    if final { target.final += text } else { target.partial += text }
    if target.final.count > 1600, let cue = close(.translation) { segments.append(cue) }
   } else {
    if source.start == nil { source.start = token["start_ms"] as? Int ?? max(0, arrivalMS) }
    source.end = max(source.end, token["end_ms"] as? Int ?? arrivalMS)
    if final { source.final += text } else { source.partial += text }
    if source.final.count > 1600, let cue = close(.original) { segments.append(cue) }
   }
  }
  return segments
 }
 private mutating func close(_ lane: Segment.Lane) -> Segment? {
  let current = lane == .original ? source : target
  guard !current.final.isEmpty else { return nil }
  let cue = Segment(lane: lane, text: current.final, start: current.start ?? 0,
                    end: current.end, approximate: lane == .translation)
  // A partial is not finalized by an unrelated lane's endpoint.
  var remaining = Lane()
  remaining.partial = current.partial
  if !current.partial.isEmpty { remaining.start = current.end; remaining.end = current.end }
  if lane == .original { recentSource = Transcript.rolling(recentSource, current.final); lastSource = current.final; source = remaining }
  else { recentTarget = Transcript.rolling(recentTarget, current.final); lastTarget = current.final; target = remaining }
  return cue
 }
 /// Closes the finished translation text as a cue (同声传译: a new utterance
 /// starting means the previous translation is complete).
 mutating func closeTranslation() -> Segment? { close(.translation) }
 mutating func finishFinals() -> [Segment] {
  [close(.original), close(.translation)].compactMap { $0 }
 }
 /// Keeps the last finalized text so multi-line captions have context.
 static func rolling(_ history: String, _ next: String, limit: Int = 320) -> String {
  let joined = history.isEmpty ? next : history + HistoryEntryJoin.separator(history, next) + next
  return String(joined.suffix(limit))
 }
 var caption: Caption {
  let o = source.visible.isEmpty ? recentSource : Transcript.rolling(recentSource, source.visible, limit: 400)
  let t = target.visible.isEmpty ? recentTarget : Transcript.rolling(recentTarget, target.visible, limit: 400)
  var c = Caption(original: String(o.suffix(400)), translated: String(t.suffix(400)), status: "正在识别")
  c.originalLive = source.visible.isEmpty ? lastSource : source.visible
  c.translatedLive = target.visible.isEmpty ? lastTarget : target.visible
  return c
 }
}
/// Space only between two Latin-script words; CJK text joins directly.
enum HistoryEntryJoin {
 static func separator(_ a: String, _ b: String) -> String {
  guard let x = a.unicodeScalars.last, let y = b.unicodeScalars.first else { return "" }
  if y == " " || x == " " { return "" }
  let latin = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,.!?;:'\"")
  return latin.contains(x) && latin.contains(y) ? " " : ""
 }
}
struct Recovery: Codable, Sendable {
 var transcript: Transcript
 var unarchived: [Segment]
 var offset: Int
 var status: String
 var updated = Date()
}
enum SRT {
 static func time(_ value: Int) -> String {
  let x = max(0, value)
  return String(format: "%02d:%02d:%02d,%03d", x/3600000, (x/60000)%60, (x/1000)%60, x%1000)
 }
 static func cue(_ i: Int, _ s: Int, _ e: Int, _ o: String, _ t: String) -> String {
  "\(i)\n\(time(s)) --> \(time(max(e,s+500)))\n\(o)\n\(t)\n\n"
 }
}

 
// Pure retry policy shared with offline regression tests.
enum SonioxRetry {
 static let maximumRetries = 8
 static func isFatal(_ code: Int) -> Bool { [400,401,402,403].contains(code) }
 static func delay(attempt: Int, rateLimited: Bool) -> TimeInterval {
  max(rateLimited ? 16 : 0, min(pow(2, Double(min(max(1, attempt), 5))), 30))
 }
}
