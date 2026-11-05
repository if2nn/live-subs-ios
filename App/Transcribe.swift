import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// URLSession transport for the async API. Uploads stream from a file.
struct URLSessionTransport: HTTPTransport {
 let session: URLSession
 func send(_ request: URLRequest) async throws -> (Data, Int) {
  let (data, response) = try await session.data(for: request)
  return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
 }
 func upload(_ request: URLRequest, fromFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, Int) {
  let delegate = UploadProgress(progress)
  let (data, response) = try await session.upload(for: request, fromFile: fromFile, delegate: delegate)
  return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
 }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
 let report: @Sendable (Double) -> Void
 init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
 func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
  guard totalBytesExpectedToSend > 0 else { return }
  report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
 }
}

/// 音频转录 jobs: import, convert, upload, poll, fetch, clean up. Persists to
/// Jobs.json after every step so a killed app resumes where it stopped.
@MainActor @Observable
final class TranscribeStore {
 var jobs: [TranscriptionJob] = []
 var message = ""
 @ObservationIgnored private var loop: Task<Void, Never>?
 @ObservationIgnored private weak var history: HistoryStore?
 @ObservationIgnored private let fm = FileManager.default

 private var support: URL? {
  guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
  let dir = base.appendingPathComponent("Transcribe", isDirectory: true)
  try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
 }
 private var jobFile: JobFile? { support.map { JobFile(url: $0.appendingPathComponent("Jobs.json")) } }
 private var work: URL {
  let dir = fm.temporaryDirectory.appendingPathComponent("transcribe", isDirectory: true)
  try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
 }

 func attach(_ history: HistoryStore) {
  self.history = history
  if jobs.isEmpty { jobs = jobFile?.load() ?? [] }
  resume()
 }
 private func persist() { jobFile?.save(jobs) }

 /// Copies the picked file into the app, checks duration, converts if needed.
 func add(_ url: URL, options: TranscribeOptions) async {
  let scoped = url.startAccessingSecurityScopedResource()
  defer { if scoped { url.stopAccessingSecurityScopedResource() } }
  guard !Store.key().isEmpty else { message = S.noKey; return }
  let active = jobs.filter { [.pending, .converting, .uploading].contains($0.state) }.count
  guard active < SonioxAsync.maximumConcurrentUploads else { message = S.tooManyUploads; return }
  let id = UUID().uuidString
  let name = url.lastPathComponent
  let copy = work.appendingPathComponent(id + "." + url.pathExtension.lowercased())
  do { try fm.copyItem(at: url, to: copy) } catch { message = S.fileUnreadable; return }
  let asset = AVURLAsset(url: copy)
  let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
  if seconds > SonioxAsync.maximumMinutes * 60 {
   try? fm.removeItem(at: copy); message = S.fileTooLong; return
  }
  var job = TranscriptionJob(id: id, fileName: name, localPath: copy.path, durationSeconds: seconds > 0 ? seconds : nil, options: options, created: Date())
  if SonioxAsync.needsConversion(name) {
   job.state = .converting
   jobs.insert(job, at: 0); persist()
   if let out = await convert(copy, id: id) {
    try? fm.removeItem(at: copy)
    job.localPath = out.path
    job.fileName = (name as NSString).deletingPathExtension + ".m4a"
    job.state = .pending
   } else {
    try? fm.removeItem(at: copy)
    job.localPath = nil; job.state = .failed; job.error = S.formatUnsupported
   }
   replace(job)
  } else {
   jobs.insert(job, at: 0); persist()
  }
  message = ""
  Diagnostics.record("transcribe.added")
  resume()
 }

 private func convert(_ input: URL, id: String) async -> URL? {
  let out = work.appendingPathComponent(id + "-converted.m4a")
  try? fm.removeItem(at: out)
  guard let export = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetAppleM4A) else { return nil }
  do { try await export.export(to: out, as: .m4a); return out }
  catch { Diagnostics.record("transcribe.convert.failed"); return nil }
 }

 private func replace(_ job: TranscriptionJob) {
  if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.insert(job, at: 0) }
  persist()
 }

 func remove(_ job: TranscriptionJob) {
  if let path = job.localPath { try? fm.removeItem(atPath: path) }
  // Remote deletes still owed stay queued until they go through.
  if job.deleteFile || job.deleteTranscription {
   var j = job; if j.state.isActive && j.state != .cleanup { j.state = .failed; j.error = S.cancelled }
   replace(j); resume(); return
  }
  jobs.removeAll { $0.id == job.id }; persist()
 }

 /// One loop drives every job; polling follows SonioxAsync.pollDelay.
 func resume() {
  guard loop == nil else { return }
  loop = Task { [weak self] in
   while let self, !Task.isCancelled {
    let pending = self.jobs.filter { $0.state.isActive && $0.state != .converting || $0.deleteFile || $0.deleteTranscription }
    if pending.isEmpty { break }
    let key = Store.key()
    if key.isEmpty { self.message = S.noKey; break }
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForResource = 3 * 3600
    let runner = TranscriptionRunner(key: key, transport: URLSessionTransport(session: URLSession(configuration: config)), workDirectory: self.work)
    var waitPoll = 10.0
    for job in pending {
     let id = job.id
     let step = await runner.advance(job) { value in
      Task { @MainActor in
       if let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].state == .uploading { self.jobs[i].progress = value }
      }
     }
     var updated = step.job
     if let segments = step.segments { updated.recordID = self.saveRecord(updated, segments) }
     self.replace(updated)
     if [.queued, .processing].contains(updated.state) {
      waitPoll = min(waitPoll, SonioxAsync.pollDelay(secondsSinceQueued: Date().timeIntervalSince(updated.queuedAt ?? Date())))
     } else if updated.state.isActive || updated.error == "网络中断，稍后重试" {
      waitPoll = min(waitPoll, updated.error == nil ? 0.2 : 10)
     }
    }
    try? await Task.sleep(for: .seconds(waitPoll))
   }
   self?.loop = nil
  }
 }

 private func saveRecord(_ job: TranscriptionJob, _ segments: [Segment]) -> String {
  let id = "FILE-" + job.id
  var entry = HistoryEntry(id: id, started: job.created, updated: Date(), source: job.options.hints.first ?? "auto",
   target: job.options.output == .translate ? job.options.target : (job.options.hints.first ?? "auto"),
   kind: .file, fileName: job.fileName,
   options: HistoryEntry.Options(translation: job.options.translation.kind, hints: job.options.hints))
  entry.append(segments)
  entry.ended = Date()
  history?.save(entry)
  Diagnostics.record("transcribe.completed")
  return id
 }

 /// 回到前台立即查一次 (plan §4.2).
 func foreground() {
  loop?.cancel(); loop = nil
  resume()
 }

 #if DEBUG
 /// UI-test fixture: one finished and one failed job, no network.
 func seedForUITests(_ history: HistoryStore) {
  var done = TranscriptionJob(id: "UITEST-JOB-1", fileName: "talk.wav", options: TranscribeOptions(), state: .completed, created: Date(timeIntervalSince1970: 1_800_000_000))
  var entry = HistoryEntry(id: "FILE-UITEST-JOB-1", started: done.created, updated: done.created, source: "en", target: "zh", kind: .file, fileName: "talk.wav")
  entry.append(SonioxAsync.lines(from: [["text": "Good morning.", "start_ms": 0, "end_ms": 900], ["text": "早上好。", "translation_status": "translation"]]))
  entry.ended = done.created
  history.save(entry)
  done.recordID = entry.id
  let failed = TranscriptionJob(id: "UITEST-JOB-2", fileName: "bad.mov", options: TranscribeOptions(), state: .failed, error: S.formatUnsupported, created: Date(timeIntervalSince1970: 1_800_000_100))
  jobs = [failed, done]; persist()
 }
 #endif
}

struct TranscribeView: View {
 @Environment(HistoryStore.self) private var history
 @Environment(TranscribeStore.self) private var store
 @Environment(\.scenePhase) private var phase
 @AppStorage("Dual.transcribe.options") private var optionsData = Data()
 @State private var options = TranscribeOptions()
 @State private var picking = false
 @State private var picked: URL?

 var body: some View {
  NavigationStack {
   Form {
    Section {
     Button { picking = true } label: { Label(S.pickFile, systemImage: "plus") }
      .accessibilityIdentifier("transcribe.pick")
     if let picked { LabeledContent(S.picked, value: picked.lastPathComponent).accessibilityIdentifier("transcribe.picked") }
    }
    Section {
     Picker(S.output, selection: $options.output) {
      Text(S.outputTranscribe).tag(TranscribeOptions.Output.transcribe)
      Text(S.outputTranslate).tag(TranscribeOptions.Output.translate)
     }.pickerStyle(.segmented).accessibilityIdentifier("transcribe.output")
     if options.output == .translate {
      Picker(S.translateTo, selection: $options.target) {
       ForEach(Language.all) { Text($0.name).tag($0.code) }
      }.accessibilityIdentifier("transcribe.target")
     }
     Picker(S.language, selection: $options.languageMode) {
      Text(S.langAuto).tag(TranscribeOptions.LanguageMode.auto)
      Text(S.langSingle).tag(TranscribeOptions.LanguageMode.single)
      Text(S.langMultiple).tag(TranscribeOptions.LanguageMode.multiple)
     }.pickerStyle(.segmented).accessibilityIdentifier("transcribe.languageMode")
     switch options.languageMode {
     case .auto: EmptyView()
     case .single:
      Picker(S.langSingle, selection: $options.single) {
       ForEach(Language.all) { Text($0.name).tag($0.code) }
      }
     case .multiple:
      NavigationLink {
       List(Language.all) { lang in
        Button {
         if let i = options.multiple.firstIndex(of: lang.code) { if options.multiple.count > 1 { options.multiple.remove(at: i) } }
         else { options.multiple.append(lang.code) }
        } label: {
         HStack { Text(lang.name).foregroundStyle(.primary); Spacer(); if options.multiple.contains(lang.code) { Image(systemName: "checkmark") } }
        }
       }.navigationTitle(S.langMultiple)
      } label: {
       LabeledContent(S.langMultiple, value: options.multiple.compactMap { c in Language.all.first { $0.code == c }?.name }.joined(separator: "、"))
      }
     }
     if options.languageMode != .auto {
      Toggle(S.strict, isOn: $options.strict).accessibilityIdentifier("transcribe.strict")
     }
    }
    Section {
     Button {
      guard let url = picked else { return }
      Task { await store.add(url, options: options); picked = nil }
     } label: { Text(S.startTranscribe).frame(maxWidth: .infinity) }
      .buttonStyle(.borderedProminent)
      .disabled(picked == nil)
      .accessibilityIdentifier("transcribe.start")
     if !store.message.isEmpty { Text(store.message).foregroundStyle(.orange).accessibilityIdentifier("transcribe.message") }
    }
    if !store.jobs.isEmpty {
     Section(S.jobs) {
      ForEach(store.jobs) { job in row(job) }
       .onDelete { idx in idx.map { store.jobs[$0] }.forEach(store.remove) }
     }
    }
   }
   .navigationTitle(S.titleTranscribe).navigationBarTitleDisplayMode(.inline)
   .toolbar { RecordsToolbarItem() }
   .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie, .mpeg4Movie, .audiovisualContent]) { result in
    if case .success(let url) = result { picked = url }
   }
   .onAppear {
    if let o = try? JSONDecoder().decode(TranscribeOptions.self, from: optionsData) { options = o }
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--ui-testing-seed-transcribe") { store.seedForUITests(history) }
    #endif
    store.attach(history)
   }
   .onChange(of: options) { optionsData = (try? JSONEncoder().encode(options)) ?? Data() }
   .onChange(of: phase) { if phase == .active { store.foreground() } }
  }
 }

 @ViewBuilder private func row(_ job: TranscriptionJob) -> some View {
  let label = HStack {
   Text(job.fileName).lineLimit(1)
   Spacer()
   Text(statusText(job)).font(.callout).foregroundStyle(job.state == .failed ? .red : .secondary)
  }
  if job.state == .completed, let rid = job.recordID, let entry = history.entries.first(where: { $0.id == rid }) {
   NavigationLink { HistoryDetailView(entry: entry) } label: { label }.accessibilityIdentifier("transcribe.job." + job.id)
  } else {
   label.accessibilityElement(children: .combine).accessibilityIdentifier("transcribe.job." + job.id)
  }
 }

 private func statusText(_ job: TranscriptionJob) -> String {
  switch job.state {
  case .pending: return S.jobPending
  case .converting: return S.jobConverting
  case .uploading: return S.jobUploading(Int(job.progress * 100))
  case .queued, .processing, .fetching: return S.jobProcessing
  case .cleanup, .completed: return S.jobDone
  case .failed: return S.jobFailed + (job.error ?? "")
  }
 }
}
