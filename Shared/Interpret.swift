import Foundation

/// 同声传译 · 对话 (plan §13.3). Two-way translation returns every utterance in
/// both languages: the spoken original and its translation. Each half of the
/// screen shows the text in its own reader's language, so tokens are routed by
/// their `language` field, not by speaker (diarization stays off, D4).
///   near half (me, language A): A originals + translations into A
///   far half  (opposite, language B): B originals + translations into B
/// Control tokens (<end>, <fin>) carry no language and go to both halves.
/// Foundation only, so FeatureTests can run it on Linux.
struct ConversationRouter: Sendable {
 let languageA: String
 let languageB: String
 var near = Transcript()
 var far = Transcript()

 init(languageA: String, languageB: String) {
  self.languageA = languageA; self.languageB = languageB
 }

 enum Side: String, Sendable { case near, far }

 /// Which half a token belongs to, or nil for control tokens (both halves).
 func side(of token: [String: Any]) -> Side? {
  guard let language = token["language"] as? String, !language.isEmpty else { return nil }
  if language == languageA { return .near }
  if language == languageB { return .far }
  // A language outside the pair (misdetection): show it where its translation
  // is not, i.e. treat originals as the far speaker's and translations by target.
  return token["translation_status"] as? String == "translation" ? nil : .far
 }

 /// Returns finished segments per half.
 mutating func ingest(_ tokens: [[String: Any]], arrivalMS: Int = 0) -> (near: [Segment], far: [Segment]) {
  var nearTokens: [[String: Any]] = []
  var farTokens: [[String: Any]] = []
  for token in tokens {
   switch side(of: token) {
   case .near: nearTokens.append(token)
   case .far: farTokens.append(token)
   case nil:
    let text = token["text"] as? String ?? ""
    if text == "<end>" || text == "<fin>" { nearTokens.append(token); farTokens.append(token) }
   }
  }
  return (ConversationRouter.feed(&near, nearTokens, arrivalMS: arrivalMS),
          ConversationRouter.feed(&far, farTokens, arrivalMS: arrivalMS))
 }

 /// Feeds tokens and closes the pending translation cue as soon as a new
 /// original utterance starts, so translations do not pile up until stop.
 static func feed(_ t: inout Transcript, _ tokens: [[String: Any]], arrivalMS: Int) -> [Segment] {
  var out: [Segment] = []
  let startsOriginal = tokens.contains { token in
   guard let text = token["text"] as? String, text != "<end>", text != "<fin>" else { return false }
   return token["translation_status"] as? String != "translation"
  }
  if startsOriginal, !t.target.final.isEmpty, t.source.final.isEmpty, t.source.partial.isEmpty,
     let cue = t.closeTranslation() { out.append(cue) }
  out += t.ingest(tokens, arrivalMS: arrivalMS)
  return out
 }
}
