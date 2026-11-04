import XCTest
@testable import LiveSubsMac

final class RegressionTests: XCTestCase {
 func testPreview4ProtocolConfiguration() throws {
  let json = SonioxConfig.dictionary(LanguageSettings())
  XCTAssertEqual(json["sample_rate"] as? Int, 16000)
  XCTAssertEqual(json["audio_format"] as? String, "s16le")
  XCTAssertNil(json["api_key"])
  XCTAssertEqual((json["translation"] as? [String: String])?["target_language"], "zh")
 }
 func testSameLanguageOmitsTranslation() {
  XCTAssertNil(SonioxConfig.dictionary(LanguageSettings(source: "en", target: "en"))["translation"])
 }
 func testPartialAppearsBeforeTranslation() {
  var transcript = Transcript()
  XCTAssertTrue(transcript.ingest([["text": "hello", "is_final": false]]).isEmpty)
  XCTAssertEqual(transcript.caption.originalLive, "hello")
  XCTAssertEqual(transcript.caption.translated, "")
 }
 func testIndependentEndpoints() {
  var transcript = Transcript()
  let source = transcript.ingest([
   ["text": "Hello.", "is_final": true, "start_ms": 0, "end_ms": 800],
   ["text": "<end>", "is_final": true],
   ["text": "你好", "translation_status": "translation", "is_final": false]
  ], arrivalMS: 1000)
  XCTAssertEqual(source.count, 1)
  XCTAssertEqual(source.first?.lane, .original)
  XCTAssertEqual(transcript.target.partial, "你好")
  let translated = transcript.ingest([
   ["text": "你好。", "translation_status": "translation", "is_final": true],
   ["text": "<end>", "translation_status": "translation", "is_final": true]
  ], arrivalMS: 1200)
  XCTAssertEqual(translated.first?.lane, .translation)
  XCTAssertEqual(translated.first?.approximate, true)
 }
 func testHistoryRoundTripAndExports() throws {
  let now = Date(timeIntervalSince1970: 1000)
  var entry = HistoryEntry(id: "fixture-1", started: now, updated: now, source: "en", target: "zh")
  entry.append([Segment(lane: .original, text: "Hello", start: 0, end: 700, approximate: false),
                Segment(lane: .translation, text: "你好", start: 900, end: 900, approximate: true)])
  XCTAssertEqual(HistoryEntry.decode(try XCTUnwrap(entry.encoded())), entry)
  XCTAssertTrue(entry.plainText(.bilingual).contains("你好"))
  XCTAssertTrue(entry.srt(.bilingual).contains("00:00:00,000 -->"))
  XCTAssertFalse(entry.plainText(.translationOnly).contains("Hello"))
 }
 func testStyleClamping() {
  var style = SubtitleStyle(); style.fontSize = .nan; style.lines = 99; style.backgroundOpacity = -1
  XCTAssertEqual(style.normalized().fontSize, 30)
  XCTAssertEqual(style.normalized().lines, 4)
  XCTAssertEqual(style.normalized().backgroundOpacity, 0.3)
 }
 func testPCMStreamingChunking() {
  var resampler = SpeechResampler(inputRate: 48000)
  var chunker = SpeechChunker()
  let first = chunker.append(resampler.process(Array(repeating: 0.5, count: 2400)))
  XCTAssertTrue(first.isEmpty)
  let second = chunker.append(resampler.process(Array(repeating: 0.5, count: 2400)))
  XCTAssertEqual(second.count, 1)
  XCTAssertEqual(second.first?.count, 3200)
  XCTAssertNil(chunker.drain())
 }
 func testRetryAndPathValidation() {
  XCTAssertTrue(SonioxRetry.isFatal(401))
  XCTAssertFalse(SonioxRetry.isFatal(429))
  XCTAssertGreaterThanOrEqual(SonioxRetry.delay(attempt: 1, rateLimited: true), 16)
  XCTAssertFalse(HistoryEntry.safeID("../escape"))
 }
}
