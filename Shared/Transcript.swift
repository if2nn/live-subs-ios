import Foundation

struct Caption: Codable {
 var original = ""; var translated = ""; var status = "等待广播"; var updated = Date()
}
struct Segment: Codable {
 enum Lane: String, Codable { case original, translation }
 var lane: Lane
 var text: String
 var start: Int
 var end: Int
 var approximate: Bool
}
struct Transcript: Codable {
 struct Lane: Codable {
  var final = ""; var partial = ""; var start: Int?; var end = 0
  var visible: String { final + partial }
 }
 var source = Lane()
 var target = Lane()
 var recentSource = ""
 var recentTarget = ""
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
  if lane == .original { recentSource = current.final; source = remaining }
  else { recentTarget = current.final; target = remaining }
  return cue
 }
 mutating func finishFinals() -> [Segment] {
  [close(.original), close(.translation)].compactMap { $0 }
 }
 var caption: Caption {
  Caption(original: String((source.visible.isEmpty ? recentSource : source.visible).suffix(400)),
          translated: String((target.visible.isEmpty ? recentTarget : target.visible).suffix(400)),
          status: "正在识别")
 }
}
struct Recovery: Codable {
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
