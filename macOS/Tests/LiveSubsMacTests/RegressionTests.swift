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

 func testConnectionOffsetUsesFirstAcceptedAudioAfterBackoff() {
  let began = Date(timeIntervalSince1970: 1000)
  var timeline = ConnectionTimeline()
  timeline.firstAudio(at: began.addingTimeInterval(0.25), sessionStart: began)
  XCTAssertEqual(timeline.offsetMS, 250)
  // Reconnection backoff plus connection setup must remain in the timeline.
  timeline.firstAudio(at: began.addingTimeInterval(34.5), sessionStart: began)
  XCTAssertEqual(timeline.offsetMS, 34500)
 }

 @MainActor
 func testOrderedMessagesReconnectAndFinishBarrier() async throws {
  let model = MacModel(saveHistory: { _ in }, loadHistory: { [] }, readKey: { "" })
  let now = Date()
  model.current = HistoryEntry(id: "ordered", started: now, updated: now, source: "en", target: "zh")
  let socket = Soniox()
  model.connectEvents(socket)
  defer { model.closeEvents() }
  let first = try JSONSerialization.data(withJSONObject: ["tokens": [
   ["text": "before", "is_final": true, "start_ms": 0, "end_ms": 500]
  ]])
  let last = try JSONSerialization.data(withJSONObject: ["tokens": [
   ["text": "after", "is_final": true, "start_ms": 0, "end_ms": 500],
   ["text": "<end>", "is_final": true]
  ], "finished": true])
  socket.queue.async {
   socket.orderedEvent?(.firstAudio(now))
   socket.orderedEvent?(.message(first))
   socket.orderedEvent?(.reconnect)
   socket.orderedEvent?(.firstAudio(now.addingTimeInterval(30)))
   socket.orderedEvent?(.message(last))
  }
  await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
   socket.finish { _ in waiter.resume() }
  }
  await model.socketBarrier(socket)
  XCTAssertEqual(model.current?.lines.map(\.text), ["before", "after"])
  let lines = try XCTUnwrap(model.current?.lines)
  XCTAssertGreaterThanOrEqual(lines[1].startMS - lines[0].startMS, 29999)
 }

 @MainActor
 func testFailedSaveRetainsSessionAndBlocksNewCaptureAndStop() async {
  let model = MacModel(saveHistory: { _ in throw CocoaError(.fileWriteNoPermission) },
                       loadHistory: { [] }, readKey: { "" })
  let now = Date()
  var entry = HistoryEntry(id: "unsaved", started: now, updated: now, source: "en", target: "zh")
  entry.pendingOriginal = "keep this"
  model.current = entry
  XCTAssertFalse(model.persist())
  XCTAssertTrue(model.hasUnsavedHistory)
  await model.start()
  XCTAssertEqual(model.current, entry)
  let stopped = await model.stop()
  XCTAssertFalse(stopped)
  XCTAssertEqual(model.current, entry)
  XCTAssertFalse(model.running)
 }

 @MainActor
 func testSaveRetryClearsUnsavedAndListReadFailureDoesNotUndoSave() {
  var fail = true
  var saved: [HistoryEntry] = []
  let model = MacModel(saveHistory: {
   if fail { throw CocoaError(.fileWriteNoPermission) }
   saved.append($0)
  }, loadHistory: { throw CocoaError(.fileReadNoPermission) }, readKey: { "" })
  let now = Date()
  var entry = HistoryEntry(id: "retry", started: now, updated: now, source: "en", target: "zh")
  entry.pendingOriginal = "retained"
  model.current = entry
  XCTAssertFalse(model.persist())
  fail = false
  XCTAssertTrue(model.persist())
  XCTAssertFalse(model.hasUnsavedHistory)
  XCTAssertEqual(saved, [entry])
 }

 @MainActor
 func testInvalidHistoryIDIsAnExplicitSaveFailure() {
  let now = Date()
  let entry = HistoryEntry(id: "../invalid", started: now, updated: now, source: "en", target: "zh")
  XCTAssertThrowsError(try Archive.save(entry))
 }
}
