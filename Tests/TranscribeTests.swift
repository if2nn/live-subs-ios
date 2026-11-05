import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 音频转录 job state machine against a scripted fake transport (no network,
/// no real Soniox request). Covers success, failure, restart resume, both
/// DELETEs, request bodies, options, and format/duration rules.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
 struct Call: Sendable { let method: String; let path: String; let body: [String: String]; let auth: Bool }
 private let lock = NSLock()
 private var _calls: [Call] = []
 var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
 /// method + " " + path -> (status, json)
 var routes: [String: (Int, String)] = [:]
 var failNext: String? = nil
 private func record(_ r: URLRequest) -> (Int, Data) {
  let method = r.httpMethod ?? "GET"
  let path = r.url!.path.replacingOccurrences(of: "/v1/", with: "")
  var body: [String: String] = [:]
  if let data = r.httpBody, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
   for (k, v) in obj { body[k] = String(describing: v) }
  }
  lock.lock(); _calls.append(Call(method: method, path: path, body: body, auth: r.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")); lock.unlock()
  let key = method + " " + path
  let (status, json) = routes[key] ?? (404, "{}")
  return (status, Data(json.utf8))
 }
 func send(_ request: URLRequest) async throws -> (Data, Int) {
  if let f = failNext, f == (request.httpMethod ?? "GET") + " " + request.url!.path.replacingOccurrences(of: "/v1/", with: "") {
   failNext = nil; throw URLError(.networkConnectionLost)
  }
  let (s, d) = record(request); return (d, s)
 }
 func upload(_ request: URLRequest, fromFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, Int) {
  let body = (try? Data(contentsOf: fromFile)) ?? Data()
  precondition(String(decoding: body, as: UTF8.self).contains("name=\"file\"; filename=\"talk.wav\""), "multipart file field")
  precondition(String(decoding: body, as: UTF8.self).contains("RIFFDATA"), "multipart carries the file bytes")
  progress(1)
  let (s, d) = record(request); return (d, s)
 }
}

@main @MainActor struct TranscribeTests {
 static var checks = 0
 static func check(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), m); checks += 1 }

 static func main() async {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-tests-" + UUID().uuidString)
  try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  func localFile() -> String {
   let p = dir.appendingPathComponent(UUID().uuidString + ".wav").path
   FileManager.default.createFile(atPath: p, contents: Data("RIFFDATA".utf8)); return p
  }

  // Request body per option.
  var o = TranscribeOptions()
  var b = SonioxAsync.createBody(fileID: "f1", options: o, reference: "dual-1")
  check(b["model"] as? String == "stt-async-v6" && b["language_hints"] == nil && b["translation"] == nil, "auto + transcribe only")
  check(b["client_reference_id"] as? String == "dual-1" && b["api_key"] == nil, "reference id, no key in body")
  o.output = .translate; o.target = "zh"; o.languageMode = .single; o.single = "en"
  b = SonioxAsync.createBody(fileID: "f1", options: o, reference: "r")
  check(b["language_hints"] as? [String] == ["en"] && b["language_hints_strict"] == nil, "single language")
  check(b["translation"] as? [String: String] == ["type": "one_way", "target_language": "zh"], "translate one_way")
  o.languageMode = .multiple; o.multiple = ["en", "ja", "en"]; o.strict = true
  b = SonioxAsync.createBody(fileID: "f1", options: o, reference: "r")
  check(b["language_hints"] as? [String] == ["en", "ja"] && b["language_hints_strict"] as? Bool == true, "multiple deduped + strict")
  o.languageMode = .auto
  check(SonioxAsync.createBody(fileID: "f1", options: o, reference: "r")["language_hints_strict"] == nil, "strict ignored for auto")

  // Formats, duration, polling.
  check(!SonioxAsync.needsConversion("a.M4A") && !SonioxAsync.needsConversion("b.mp3") && SonioxAsync.needsConversion("c.mov") && SonioxAsync.needsConversion("noext"), "format table")
  check(SonioxAsync.maximumMinutes == 300, "300 minute limit")
  check(SonioxAsync.pollDelay(secondsSinceQueued: 5) == 3 && SonioxAsync.pollDelay(secondsSinceQueued: 45) == 10, "poll schedule")
  check(SonioxAsync.message(status: 401) == "API Key 无效" && SonioxAsync.message(status: 402) == "余额不足" && SonioxAsync.message(status: 0, errorType: "audio_too_long") == "文件超过 300 分钟", "error copy")

  // Transcript tokens -> lines.
  let lines = SonioxAsync.lines(from: [
   ["text": "Hello", "start_ms": 0, "end_ms": 400, "translation_status": "original"],
   ["text": " world.", "start_ms": 400, "end_ms": 900, "translation_status": "original"],
   ["text": "你好世界。", "translation_status": "translation"],
   ["text": "Bye.", "start_ms": 1000, "end_ms": 1300, "translation_status": "original"],
   ["text": "再见。", "translation_status": "translation"]
  ])
  check(lines.map(\.text) == ["Hello world.", "你好世界。", "Bye.", "再见。"], "async lines: \(lines.map(\.text))")
  check(lines[0].start == 0 && lines[2].start == 1000, "original timing kept")
  var entry = HistoryEntry(id: "F-1", started: Date(), updated: Date(), source: "auto", target: "zh", kind: .file, fileName: "talk.wav")
  entry.append(lines)
  check(entry.rows.count == 2 && entry.rows[1].translation == "再见。", "rows pair original and translation")

  // Full success path with both deletes.
  let t = FakeTransport()
  t.routes = [
   "POST files": (201, #"{"id":"file-1","filename":"talk.wav","size":8}"#),
   "POST transcriptions": (201, #"{"id":"tr-1","status":"queued"}"#),
   "GET transcriptions/tr-1": (200, #"{"id":"tr-1","status":"processing"}"#),
   "GET transcriptions/tr-1/transcript": (200, #"{"text":"Hi.","tokens":[{"text":"Hi.","start_ms":0,"end_ms":300}]}"#),
   "DELETE transcriptions/tr-1": (204, ""),
   "DELETE files/file-1": (204, "")
  ]
  let runner = TranscriptionRunner(key: "test-key", transport: t, workDirectory: dir)
  let path = localFile()
  var job = TranscriptionJob(id: "J1", fileName: "talk.wav", localPath: path, options: TranscribeOptions(), created: Date())
  job = await runner.advance(job).job
  check(job.state == .uploading, "pending -> uploading")
  job = await runner.advance(job).job
  check(job.state == .queued && job.fileID == "file-1" && job.transcriptionID == "tr-1", "uploaded and created")
  check(job.localPath == nil && !FileManager.default.fileExists(atPath: path), "local copy removed after upload")
  check(t.calls.allSatisfy(\.auth), "every call has the bearer header")
  check(t.calls.last?.body["file_id"] == "file-1", "create uses the uploaded file id")
  job = await runner.advance(job).job
  check(job.state == .processing, "processing")
  // App restart: reload from Jobs.json and continue without uploading again.
  let jobFile = JobFile(url: dir.appendingPathComponent("Jobs.json"))
  jobFile.save([job])
  job = jobFile.load()[0]
  check(job.transcriptionID == "tr-1" && job.state == .processing, "job survives restart")
  t.routes["GET transcriptions/tr-1"] = (200, #"{"id":"tr-1","status":"completed"}"#)
  job = await runner.advance(job).job
  check(job.state == .fetching, "completed -> fetching")
  let fetched = await runner.advance(job)
  check(fetched.segments?.first?.text == "Hi." && fetched.job.state == .cleanup, "transcript fetched")
  job = await runner.advance(fetched.job).job
  check(job.state == .completed && !job.deleteFile && !job.deleteTranscription, "completed after cleanup")
  let deletes = t.calls.filter { $0.method == "DELETE" }.map(\.path)
  check(deletes == ["transcriptions/tr-1", "files/file-1"], "both DELETEs, transcription first: \(deletes)")
  check(t.calls.filter { $0.method == "POST" && $0.path == "files" }.count == 1, "uploaded exactly once")

  // Server-side error: fails, still deletes both.
  let t2 = FakeTransport()
  t2.routes = [
   "POST files": (201, #"{"id":"file-2"}"#),
   "POST transcriptions": (201, #"{"id":"tr-2","status":"queued"}"#),
   "GET transcriptions/tr-2": (200, #"{"id":"tr-2","status":"error","error_type":"unsupported_audio_format","error_message":"x"}"#),
   "DELETE transcriptions/tr-2": (204, ""),
   "DELETE files/file-2": (404, "{}")
  ]
  let r2 = TranscriptionRunner(key: "test-key", transport: t2, workDirectory: dir)
  var j2 = TranscriptionJob(id: "J2", fileName: "talk.wav", localPath: localFile(), options: TranscribeOptions(), created: Date())
  for _ in 0..<3 { j2 = await r2.advance(j2).job }
  check(j2.state == .failed && j2.error == "格式不支持", "server error mapped: \(j2.error ?? "")")
  j2 = await r2.advance(j2).job
  check(t2.calls.filter { $0.method == "DELETE" }.map(\.path) == ["transcriptions/tr-2", "files/file-2"], "failed job still deletes both")
  check(!j2.deleteFile && !j2.deleteTranscription && j2.state == .failed, "404 on delete counts as gone")

  // Upload rejected (401): fails without remote deletes owed.
  let t3 = FakeTransport(); t3.routes = ["POST files": (401, #"{"error_type":"unauthenticated"}"#)]
  var j3 = TranscriptionJob(id: "J3", fileName: "talk.wav", localPath: localFile(), state: .uploading, created: Date())
  j3.options = TranscribeOptions()
  j3 = await TranscriptionRunner(key: "test-key", transport: t3, workDirectory: dir).advance(j3).job
  check(j3.state == .failed && j3.error == "API Key 无效" && !j3.deleteFile && j3.localPath == nil, "401 upload fails cleanly")

  // Network drop while polling: state kept, retried next pass.
  let t4 = FakeTransport(); t4.routes = ["GET transcriptions/tr-4": (200, #"{"status":"completed"}"#)]
  t4.failNext = "GET transcriptions/tr-4"
  var j4 = TranscriptionJob(id: "J4", fileName: "a.mp3", options: TranscribeOptions(), state: .queued, fileID: "f4", transcriptionID: "tr-4", created: Date())
  j4 = await TranscriptionRunner(key: "test-key", transport: t4, workDirectory: dir).advance(j4).job
  check(j4.state == .queued && j4.error != nil, "network drop keeps state")
  j4 = await TranscriptionRunner(key: "test-key", transport: t4, workDirectory: dir).advance(j4).job
  check(j4.state == .fetching, "retry succeeds")

  print("TranscribeTests PASS (\(checks) checks: request bodies, formats, polling, lines, success, error, restart resume, deletes, network retry)")
 }
}
