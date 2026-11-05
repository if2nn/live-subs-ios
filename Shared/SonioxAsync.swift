import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 音频转录 (plan §3.3, §4.2): Soniox async REST. Foundation only so the whole
/// job state machine runs in offline tests against a fake transport.

/// Options chosen on the 音频转录 page.
struct TranscribeOptions: Codable, Sendable, Equatable {
 enum Output: String, Codable, Sendable, CaseIterable { case transcribe, translate }
 enum LanguageMode: String, Codable, Sendable, CaseIterable { case auto, single, multiple }
 var output: Output = .transcribe
 var target: String = "zh"
 var languageMode: LanguageMode = .auto
 var single: String = "en"
 var multiple: [String] = ["en", "zh"]
 /// 仅识别所选语言 (language_hints_strict). Ignored for 自动.
 var strict = false

 var hints: [String] {
  switch languageMode {
  case .auto: return []
  case .single: return [single]
  case .multiple: return SonioxConfig.unique(multiple)
  }
 }
 var translation: SonioxConfig.Translation { output == .translate ? .oneWay(target: target) : .none }
}

enum SonioxAsync {
 static let model = "stt-async-v6"
 static let base = URL(string: "https://api.soniox.com/v1")!
 /// Fixed Soniox limit per file (minutes).
 static let maximumMinutes = 300.0
 /// Containers Soniox accepts as-is; anything else is converted to m4a first.
 static let supportedExtensions: Set<String> = ["aac", "aiff", "aif", "amr", "asf", "flac", "mp3", "ogg", "wav", "webm", "m4a", "mp4"]
 static func needsConversion(_ fileName: String) -> Bool {
  !supportedExtensions.contains((fileName as NSString).pathExtension.lowercased())
 }
 /// App-side cap on simultaneous uploads (plan §4.2).
 static let maximumConcurrentUploads = 3

 static func createBody(fileID: String, options: TranscribeOptions, reference: String) -> [String: Any] {
  var body: [String: Any] = [
   "model": model,
   "file_id": fileID,
   "enable_language_identification": true,
   "client_reference_id": reference
  ]
  let hints = options.hints
  if !hints.isEmpty {
   body["language_hints"] = hints
   if options.strict { body["language_hints_strict"] = true }
  }
  if let t = options.translation.dictionary { body["translation"] = t }
  return body
 }

 /// Poll every 3 s for the first 30 s of processing, then every 10 s.
 static func pollDelay(secondsSinceQueued: Double) -> Double { secondsSinceQueued < 30 ? 3 : 10 }

 /// multipart/form-data with one `file` field, written to a temp file so large
 /// audio is streamed from disk rather than held in memory.
 static func multipartFile(for source: URL, fileName: String, boundary: String, in directory: URL) throws -> URL {
  let out = directory.appendingPathComponent("upload-" + UUID().uuidString)
  FileManager.default.createFile(atPath: out.path, contents: nil)
  let handle = try FileHandle(forWritingTo: out)
  defer { try? handle.close() }
  let safeName = fileName.replacingOccurrences(of: "\"", with: "")
  handle.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
  let input = try FileHandle(forReadingFrom: source)
  defer { try? input.close() }
  while true {
   let chunk = input.readData(ofLength: 1 << 20)
   if chunk.isEmpty { break }
   handle.write(chunk)
  }
  handle.write(Data("\r\n--\(boundary)--\r\n".utf8))
  return out
 }

 /// Builds caption-style lines from an async transcript's tokens. Original
 /// tokens carry start/end ms; translation tokens do not and attach to the
 /// preceding original sentence (same rule as live captions).
 static func lines(from tokens: [[String: Any]]) -> [Segment] {
  var t = Transcript()
  var out: [Segment] = []
  var lastMS = 0
  var batch: [[String: Any]] = []
  var batchIsTranslation: Bool? = nil
  func flush() {
   guard !batch.isEmpty else { return }
   out += ConversationRouter.feed(&t, batch, arrivalMS: lastMS)
   batch = []
  }
  for token in tokens {
   guard let text = token["text"] as? String else { continue }
   let translation = token["translation_status"] as? String == "translation"
   if let end = token["end_ms"] as? Int { lastMS = max(lastMS, end) }
   if batchIsTranslation != nil && batchIsTranslation != translation { flush() }
   batchIsTranslation = translation
   var copy = token
   copy["is_final"] = true
   copy["text"] = text
   batch.append(copy)
   // Async transcripts have no <end> markers: close a sentence on final punctuation.
   if !translation, let last = text.trimmingCharacters(in: .whitespaces).last, "。！？.!?".contains(last) {
    batch.append(["text": "<end>", "is_final": true])
    flush()
   }
  }
  flush()
  out += t.finishFinals()
  return out
 }

 /// Short error copy for HTTP status / Soniox error types.
 static func message(status: Int, errorType: String? = nil) -> String {
  if let errorType {
   switch errorType {
   case "unsupported_audio_format", "invalid_audio": return "格式不支持"
   case "audio_too_long": return "文件超过 300 分钟"
   case "unsupported_language_pair", "unsupported_translation": return "不支持该语言组合"
   default: break
   }
  }
  switch status {
  case 401: return "API Key 无效"
  case 402: return "余额不足"
  case 403: return "Key 无此权限"
  case 408: return "连接超时"
  case 413: return "文件过大"
  case 429: return "请求过多"
  case 500...599: return "服务暂不可用"
  default: return "失败（\(status)）"
  }
 }
}

/// A transcription task, persisted in Jobs.json so it survives the app being
/// killed: file_id and transcription_id are kept, nothing is uploaded twice.
struct TranscriptionJob: Codable, Sendable, Equatable, Identifiable {
 enum State: String, Codable, Sendable {
  case pending, converting, uploading, queued, processing, fetching, cleanup, completed, failed
  var isActive: Bool { ![.completed, .failed].contains(self) }
 }
 var id: String
 var fileName: String
 /// Local copy in the app's temp/jobs directory, deleted after upload.
 var localPath: String?
 var durationSeconds: Double?
 var options = TranscribeOptions()
 var state: State = .pending
 var progress: Double = 0
 var fileID: String?
 var transcriptionID: String?
 var recordID: String?
 var error: String?
 var created: Date
 var queuedAt: Date?
 /// Remote deletes still owed (cleanup survives restarts).
 var deleteTranscription = false
 var deleteFile = false
}

/// Minimal HTTP seam: the app uses URLSession, tests use a scripted fake.
protocol HTTPTransport: Sendable {
 func send(_ request: URLRequest) async throws -> (Data, Int)
 func upload(_ request: URLRequest, fromFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, Int)
}

struct SonioxAsyncError: Error, Equatable { let message: String; let status: Int }

/// Runs one job forward step by step. Each `advance` performs at most one
/// remote call and returns the updated job, so the caller can persist between
/// steps and resume after a restart from whatever state was saved.
struct TranscriptionRunner: Sendable {
 let key: String
 let transport: HTTPTransport
 let workDirectory: URL

 private func request(_ method: String, _ path: String, json: [String: Any]? = nil) -> URLRequest {
  var r = URLRequest(url: SonioxAsync.base.appendingPathComponent(path))
  r.httpMethod = method
  r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
  if let json {
   r.setValue("application/json", forHTTPHeaderField: "Content-Type")
   r.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
  }
  r.timeoutInterval = 120
  return r
 }
 private func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

 /// Result of a step: the job, plus the record to save when the transcript arrived.
 struct Step: Sendable { var job: TranscriptionJob; var segments: [Segment]? = nil }

 func advance(_ input: TranscriptionJob, now: Date = Date(), progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Step {
  var job = input
  do {
   switch job.state {
   case .pending, .converting:
    // Conversion (mov → m4a) happens in the app before the job reaches here.
    job.state = .uploading
    return Step(job: job)
   case .uploading:
    guard let path = job.localPath, FileManager.default.fileExists(atPath: path) else {
     return Step(job: fail(job, "本地文件已丢失"))
    }
    let boundary = "dual-" + UUID().uuidString
    let body = try SonioxAsync.multipartFile(for: URL(fileURLWithPath: path), fileName: job.fileName, boundary: boundary, in: workDirectory)
    defer { try? FileManager.default.removeItem(at: body) }
    var r = request("POST", "files")
    r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    r.timeoutInterval = 3600
    let (data, status) = try await transport.upload(r, fromFile: body, progress: progress)
    guard (200..<300).contains(status), let id = object(data)["id"] as? String else {
     return Step(job: fail(job, SonioxAsync.message(status: status, errorType: object(data)["error_type"] as? String)))
    }
    job.fileID = id; job.deleteFile = true; job.progress = 1
    try? FileManager.default.removeItem(atPath: path); job.localPath = nil
    let (cdata, cstatus) = try await transport.send(request("POST", "transcriptions",
     json: SonioxAsync.createBody(fileID: id, options: job.options, reference: "dual-" + job.id)))
    guard (200..<300).contains(cstatus), let tid = object(cdata)["id"] as? String else {
     return Step(job: fail(job, SonioxAsync.message(status: cstatus, errorType: object(cdata)["error_type"] as? String)))
    }
    job.transcriptionID = tid; job.deleteTranscription = true
    job.state = .queued; job.queuedAt = now
    return Step(job: job)
   case .queued, .processing:
    guard let tid = job.transcriptionID else { return Step(job: fail(job, "任务信息丢失")) }
    let (data, status) = try await transport.send(request("GET", "transcriptions/" + tid))
    guard (200..<300).contains(status) else {
     if status == 404 { job.deleteTranscription = false; return Step(job: fail(job, "任务已过期")) }
     return Step(job: fail(job, SonioxAsync.message(status: status)))
    }
    let obj = object(data)
    switch obj["status"] as? String {
    case "completed": job.state = .fetching
    case "error":
     return Step(job: fail(job, SonioxAsync.message(status: 0, errorType: obj["error_type"] as? String)))
    case "processing": job.state = .processing
    default: job.state = .queued
    }
    return Step(job: job)
   case .fetching:
    guard let tid = job.transcriptionID else { return Step(job: fail(job, "任务信息丢失")) }
    let (data, status) = try await transport.send(request("GET", "transcriptions/\(tid)/transcript"))
    guard (200..<300).contains(status) else { return Step(job: fail(job, SonioxAsync.message(status: status))) }
    let tokens = object(data)["tokens"] as? [[String: Any]] ?? []
    job.state = .cleanup
    return Step(job: job, segments: SonioxAsync.lines(from: tokens))
   case .cleanup:
    return Step(job: try await cleanup(job, final: .completed))
   case .completed, .failed:
    if job.deleteTranscription || job.deleteFile { return Step(job: try await cleanup(job, final: job.state)) }
    return Step(job: job)
   }
  } catch {
   // Transport failure: keep the state so the next pass retries this step.
   job.error = "网络中断，稍后重试"
   return Step(job: job)
  }
 }

 /// Failure keeps any remote deletes owed; they run on the next pass.
 private func fail(_ input: TranscriptionJob, _ message: String) -> TranscriptionJob {
  var job = input
  job.state = .failed; job.error = message
  if let path = job.localPath { try? FileManager.default.removeItem(atPath: path); job.localPath = nil }
  return job
 }

 /// DELETE the transcription first, then the file (the file must outlive the
 /// transcription until it is completed or failed). 404 counts as deleted.
 private func cleanup(_ input: TranscriptionJob, final: TranscriptionJob.State) async throws -> TranscriptionJob {
  var job = input
  if job.deleteTranscription, let tid = job.transcriptionID {
   let (_, status) = try await transport.send(request("DELETE", "transcriptions/" + tid))
   if (200..<300).contains(status) || status == 404 { job.deleteTranscription = false } else { return job }
  } else { job.deleteTranscription = false }
  if job.deleteFile, let fid = job.fileID {
   let (_, status) = try await transport.send(request("DELETE", "files/" + fid))
   if (200..<300).contains(status) || status == 404 { job.deleteFile = false } else { return job }
  } else { job.deleteFile = false }
  job.state = final
  if final == .completed { job.error = nil }
  return job
 }
}

/// Jobs.json in Application Support (plan §5.2).
struct JobFile: Sendable {
 let url: URL
 func load() -> [TranscriptionJob] {
  guard let data = try? Data(contentsOf: url) else { return [] }
  return (try? JSONDecoder.history.decode([TranscriptionJob].self, from: data)) ?? []
 }
 func save(_ jobs: [TranscriptionJob]) {
  guard let data = try? JSONEncoder.history.encode(jobs) else { return }
  try? data.write(to: url, options: [.atomic])
 }
}
