import Foundation

@main struct Tests {
 static func token(_ text: String, _ lane: String = "original", _ final: Bool = true,
                   _ start: Int = 0, _ end: Int = 500) -> [String: Any] {
  ["text": text, "translation_status": lane, "is_final": final, "start_ms": start, "end_ms": end]
 }
 static func main() throws {
  precondition(SRT.time(3661234) == "01:01:01,234")
  precondition(SRT.time(-1) == "00:00:00,000")
  precondition([400,401,402,403].allSatisfy { SonioxRetry.isFatal($0) })
  precondition([408,413,429,500,503].allSatisfy { !SonioxRetry.isFatal($0) })
  precondition(SonioxRetry.maximumRetries == 8)
  precondition(SonioxRetry.delay(attempt:1,rateLimited:false) == 2)
  precondition(SonioxRetry.delay(attempt:5,rateLimited:false) == 30)
  for attempt in 1...SonioxRetry.maximumRetries {
   precondition(SonioxRetry.delay(attempt:attempt,rateLimited:true) >= 16)
   precondition(SonioxRetry.delay(attempt:attempt,rateLimited:true) <= 30)
  }
  var t = Transcript()
  precondition(t.ingest([token("Hel", "original", false)]).isEmpty)
  precondition(t.caption.original == "Hel")
  _ = t.ingest([token("Hello"), token(" world", "original", false)])
  precondition(t.caption.original == "Hello world")
  var cues = t.ingest([token(" world"), token("<end>")])
  precondition(cues.count == 1 && cues[0].text == "Hello world")
  precondition(t.caption.original == "Hello world")
  // Late translation does not require, flush, or erase the next source.
  cues = t.ingest([token("Next", "original", true, 700, 900),
                   token("你好世界", "translation"), token("<end>", "translation")], arrivalMS: 1200)
  precondition(cues.count == 1 && cues[0].lane == .translation)
  precondition(cues[0].approximate && cues[0].start == 1200)
  precondition(t.source.final == "Next")
  precondition(t.target.final.isEmpty)
  // Multiple independent boundaries within ONE response, in token order.
  cues = t.ingest([token("<end>"), token("A"), token("<end>"),
                   token("甲", "translation"), token("<end>", "translation"),
                   token("B"), token("<end>")])
  precondition(cues.map { $0.text } == ["Next", "A", "甲", "B"])
  // Target-language original may not be translated at all.
  cues = t.ingest([token("中文不需翻译", "none"), token("<end>", "none")])
  precondition(cues.count == 1 && cues[0].lane == .original)
  // One lane endpoint cannot consume the other lane's partial.
  _ = t.ingest([token("尾句", "translation", false), token("Source"), token("<end>")])
  precondition(t.target.partial == "尾句")
  let tail = t.finishFinals()
  precondition(tail.isEmpty && t.target.partial == "尾句")
  let snapshot = Recovery(transcript: t, unarchived: tail, offset: 1000, status: "未确认")
  let restored = try JSONDecoder().decode(Recovery.self, from: JSONEncoder().encode(snapshot))
  precondition(restored.transcript.target.partial == "尾句")
  // Partial hypotheses are replaced, never appended across responses.
  _ = t.ingest([token("旧", "original", false)])
  _ = t.ingest([token("新", "original", false)])
  precondition(t.source.partial == "新")
  // End-of-stream writes finalized tails without upgrading partial guesses.
  _ = t.ingest([token("final tail"), token(" uncertain", "original", false)])
  cues = t.finishFinals()
  precondition(cues.map { $0.text } == ["final tail"])
  precondition(t.source.partial == " uncertain")
  precondition(!t.caption.original.contains("<end>"))
  print("Core assertions PASS")
 }
}
