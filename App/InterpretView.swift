import AVFoundation
import SwiftUI
import UIKit

/// Microphone → 16 kHz mono s16le, off the main actor. The tap runs on the
/// audio render thread; state is guarded by a lock.
final class MicPipeline: @unchecked Sendable {
 private let engine = AVAudioEngine()
 private let lock = NSLock()
 private var resampler: SpeechResampler?
 private var chunker = SpeechChunker()
 var onChunk: (@Sendable (Data, Bool) -> Void)?

 func start() throws {
  let input = engine.inputNode
  let format = input.outputFormat(forBus: 0)
  guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "Mic", code: 1) }
  lock.lock(); resampler = SpeechResampler(inputRate: format.sampleRate); chunker = SpeechChunker(); lock.unlock()
  input.removeTap(onBus: 0)
  input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
   self?.process(buffer)
  }
  engine.prepare()
  try engine.start()
 }
 private func process(_ buffer: AVAudioPCMBuffer) {
  guard let channels = buffer.floatChannelData else { return }
  let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
  guard frames > 0, count > 0 else { return }
  var mono = [Float](repeating: 0, count: frames)
  for c in 0..<count {
   let p = channels[c]
   for i in 0..<frames { mono[i] += p[i] }
  }
  if count > 1 { let k = 1 / Float(count); for i in 0..<frames { mono[i] *= k } }
  lock.lock()
  let samples = resampler?.process(mono) ?? []
  let chunks = chunker.append(samples)
  let peak = chunker.resetPeak()
  lock.unlock()
  let voiced = SpeechChunker.dbfs(peak) > -50
  for chunk in chunks { onChunk?(chunk, voiced) }
 }
 func stop() {
  engine.inputNode.removeTap(onBus: 0)
  engine.stop()
  lock.lock(); let rest = chunker.drain(); lock.unlock()
  if let rest { onChunk?(rest, false) }
 }
}

/// 同声传译 session (plan §13). One Soniox realtime stream from the microphone;
/// 对话 = two_way routed by language into two halves, 自己听 = one_way interleaved.
@MainActor @Observable
final class InterpretSession {
 enum State: Equatable { case idle, starting, running, stopping }
 var state: State = .idle
 var status = ""
 var mode: InterpretMode = .conversation
 /// Conversation halves (near = language A, far = language B).
 var nearLines: [String] = []
 var farLines: [String] = []
 var nearLive = ""
 var farLive = ""
 /// 自己听: finished rows, plus the live tail.
 var rows: [HistoryEntry.Row] = []
 var liveOriginal = ""
 var liveTranslation = ""

 @ObservationIgnored private var soniox: Soniox?
 @ObservationIgnored private var mic: MicPipeline?
 @ObservationIgnored private var router = ConversationRouter(languageA: "zh", languageB: "en")
 @ObservationIgnored private var transcript = Transcript()
 @ObservationIgnored private var entry: HistoryEntry?
 @ObservationIgnored private var lastSave = Date.distantPast
 @ObservationIgnored private var linesAtSave = 0
 @ObservationIgnored private var startedAt = Date()
 @ObservationIgnored private weak var history: HistoryStore?

 var isRunning: Bool { state == .running || state == .starting }

 func start(settings: InterpretSettings, key: String, captionsBusy: Bool, history: HistoryStore) {
  guard state == .idle else { return }
  guard !captionsBusy else { status = S.interpretBusy; return }
  #if DEBUG
  if ProcessInfo.processInfo.arguments.contains("--ui-testing-interpret-fixture") {
   begin(settings: settings, history: history); runFixture(); return
  }
  #endif
  guard !key.isEmpty else { status = S.noKey; return }
  state = .starting; status = S.interpretStarting
  AVAudioApplication.requestRecordPermission { granted in
   Task { @MainActor in
    guard self.state == .starting else { return }
    guard granted else { self.state = .idle; self.status = S.micDenied; return }
    self.connect(settings: settings, key: key, history: history)
   }
  }
 }

 private func begin(settings: InterpretSettings, history: HistoryStore) {
  let s = settings.normalized()
  mode = s.mode
  self.history = history
  router = ConversationRouter(languageA: s.languageA, languageB: s.languageB)
  transcript = Transcript()
  nearLines = []; farLines = []; nearLive = ""; farLive = ""; rows = []; liveOriginal = ""; liveTranslation = ""
  startedAt = Date()
  let source = s.mode == .conversation ? s.languageA : s.listenSource
  let target = s.mode == .conversation ? s.languageB : s.listenTarget
  entry = HistoryEntry(id: "INT-" + UUID().uuidString, started: startedAt, updated: startedAt,
   source: source, target: target, kind: .interpret,
   options: HistoryEntry.Options(translation: s.translation.kind, interpretMode: s.mode,
    languageA: s.mode == .conversation ? s.languageA : nil, languageB: s.mode == .conversation ? s.languageB : nil, hints: s.hints))
  linesAtSave = 0; lastSave = Date()
  UIApplication.shared.isIdleTimerDisabled = true
  state = .running; status = S.interpretRunning
  Diagnostics.record("interpret.start." + s.mode.rawValue)
 }

 private func connect(settings: InterpretSettings, key: String, history: HistoryStore) {
  do {
   let session = AVAudioSession.sharedInstance()
   try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
   try session.setActive(true)
  } catch {
   state = .idle; status = S.micFailed; Diagnostics.record("interpret.audioSession.failed"); return
  }
  begin(settings: settings, history: history)
  let client = Soniox()
  client.onMessage = { [weak self] obj in
   guard let self else { return }
   let box = TokenBox(tokens: obj["tokens"] as? [[String: Any]] ?? [])
   Task { @MainActor in self.ingest(box.tokens) }
  }
  client.onFatal = { [weak self] message in
   guard let self else { return }
   Task { @MainActor in self.fatal(message) }
  }
  client.start(key, config: SonioxConfig.json(settings.normalized()))
  soniox = client
  let pipeline = MicPipeline()
  pipeline.onChunk = { [weak client] data, voiced in client?.send(data, voiced: voiced) }
  do { try pipeline.start(); mic = pipeline }
  catch { fatal(S.micFailed) }
 }

 private func ingest(_ tokens: [[String: Any]]) {
  guard state == .running || state == .stopping, !tokens.isEmpty else { return }
  let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
  switch mode {
  case .conversation:
   let out = router.ingest(tokens, arrivalMS: ms)
   applyHalves(out.near, out.far)
   entry?.append(out.near + out.far)
  case .listen:
   let segments = ConversationRouter.feed(&transcript, tokens, arrivalMS: ms)
   entry?.append(segments)
   rows = entry?.rows ?? []
   liveOriginal = transcript.source.visible
   liveTranslation = transcript.target.visible
  }
  saveIfDue()
 }

 private func applyHalves(_ n: [Segment], _ f: [Segment]) {
  nearLines += n.map(\.text); farLines += f.map(\.text)
  if nearLines.count > 400 { nearLines.removeFirst(nearLines.count - 400) }
  if farLines.count > 400 { farLines.removeFirst(farLines.count - 400) }
  nearLive = router.near.source.visible + router.near.target.visible
  farLive = router.far.source.visible + router.far.target.visible
 }

 /// Every 5 s or 20 lines (plan §5.2), so a crash keeps the latest text.
 private func saveIfDue(force: Bool = false) {
  guard var e = entry else { return }
  guard force || Date().timeIntervalSince(lastSave) >= 5 || e.lines.count - linesAtSave >= 20 else { return }
  e.updated = Date()
  if mode == .listen { e.pendingOriginal = transcript.source.visible; e.pendingTranslation = transcript.target.visible }
  entry = e
  lastSave = Date(); linesAtSave = e.lines.count
  history?.save(e)
 }

 func stop() {
  guard isRunning else { return }
  state = .stopping; status = S.interpretStopping
  mic?.stop(); mic = nil
  guard let client = soniox else { finishLocal(); return }
  client.finish(timeout: 2) { _ in Task { @MainActor in self.finishLocal() } }
 }

 private func finishLocal() {
  let finals: [Segment]
  switch mode {
  case .conversation:
   let n = router.near.finishFinals(), f = router.far.finishFinals()
   applyHalves(n, f)
   finals = n + f
  case .listen:
   finals = transcript.finishFinals()
  }
  entry?.append(finals)
  if mode == .listen { rows = entry?.rows ?? []; liveOriginal = ""; liveTranslation = "" }
  entry?.ended = Date()
  saveIfDue(force: true)
  entry = nil
  soniox?.stop(); soniox = nil
  try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  UIApplication.shared.isIdleTimerDisabled = false
  state = .idle; status = S.interpretSaved
  Diagnostics.record("interpret.stop")
 }

 private func fatal(_ message: String) {
  Diagnostics.record("interpret.fatal")
  mic?.stop(); mic = nil
  if state == .running || state == .stopping { finishLocal() } else { state = .idle }
  status = message.contains("401") ? S.keyInvalid : message.contains("402") ? S.noBalance : S.interpretFailed
 }

 #if DEBUG
 /// UI-test fixture: canned two-way / one-way tokens, no microphone, no network.
 private func runFixture() {
  // One array per server message, as Soniox delivers them.
  let batches: [[[String: Any]]]
  switch mode {
  case .conversation:
   batches = [
    [["text": "你好，请问车站怎么走？", "is_final": true, "language": "zh", "translation_status": "original", "start_ms": 0, "end_ms": 1500],
     ["text": "<end>", "is_final": true]],
    [["text": "Hello, how do I get to the station?", "is_final": true, "language": "en", "translation_status": "translation"]],
    [["text": "Go straight, then turn left.", "is_final": true, "language": "en", "translation_status": "original", "start_ms": 2000, "end_ms": 3500],
     ["text": "<end>", "is_final": true]],
    [["text": "直走，然后左转。", "is_final": true, "language": "zh", "translation_status": "translation"]]
   ]
  case .listen:
   batches = [
    [["text": "Welcome to the museum.", "is_final": true, "language": "en", "translation_status": "original", "start_ms": 0, "end_ms": 1500],
     ["text": "<end>", "is_final": true]],
    [["text": "欢迎来到博物馆。", "is_final": true, "language": "zh", "translation_status": "translation"]],
    [["text": "The tour starts at ten.", "is_final": true, "language": "en", "translation_status": "original", "start_ms": 2000, "end_ms": 3500],
     ["text": "<end>", "is_final": true]],
    [["text": "导览十点开始。", "is_final": true, "language": "zh", "translation_status": "translation"]]
   ]
  }
  for batch in batches { ingest(batch) }
 }
 #endif
}

/// Carries Soniox tokens (JSON values) across the actor hop.
private struct TokenBox: @unchecked Sendable { let tokens: [[String: Any]] }

struct InterpretView: View {
 @Environment(SettingsStore.self) private var store
 @Environment(HistoryStore.self) private var history
 @Environment(CaptionPiP.self) private var pip
 @Environment(InterpretSession.self) private var session

 var body: some View {
  @Bindable var store = store
  NavigationStack {
   VStack(spacing: 12) {
    Picker(S.interpretMode, selection: $store.settings.interpret.mode) {
     ForEach(InterpretMode.allCases) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented)
    .disabled(session.isRunning)
    .accessibilityIdentifier("interpret.mode")

    languageRow
    content.frame(maxWidth: .infinity, maxHeight: .infinity)

    if !session.status.isEmpty {
     Text(session.status).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("interpret.status")
    }
    if session.isRunning {
     Button(role: .destructive) { session.stop() } label: {
      Label(S.stop, systemImage: "stop.fill").frame(maxWidth: .infinity)
     }
     .buttonStyle(.borderedProminent).controlSize(.large)
     .disabled(session.state == .stopping)
     .accessibilityIdentifier("interpret.stop")
    } else {
     Button {
      store.persist()
      session.start(settings: store.settings.interpret, key: Store.key(), captionsBusy: pip.isActive || pip.phase == .running, history: history)
     } label: {
      Label(S.start, systemImage: "mic.fill").frame(maxWidth: .infinity)
     }
     .buttonStyle(.borderedProminent).controlSize(.large)
     .accessibilityIdentifier("interpret.start")
    }
   }
   .padding()
   .navigationTitle(S.titleInterpret)
   .navigationBarTitleDisplayMode(.inline)
   .toolbar { RecordsToolbarItem() }
   .onChange(of: store.settings.interpret) { store.persist() }
  }
 }

 @ViewBuilder private var languageRow: some View {
  @Bindable var store = store
  HStack {
   switch store.settings.interpret.mode {
   case .conversation:
    Picker(S.me, selection: $store.settings.interpret.languageA) {
     ForEach(Language.all) { Text($0.name).tag($0.code) }
    }.accessibilityIdentifier("interpret.languageA")
    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
    Picker(S.opposite, selection: $store.settings.interpret.languageB) {
     ForEach(Language.all) { Text($0.name).tag($0.code) }
    }.accessibilityIdentifier("interpret.languageB")
    Spacer()
    Toggle(isOn: $store.settings.interpret.flipOpposite) { Image(systemName: "arrow.up.arrow.down") }
     .toggleStyle(.button)
     .accessibilityLabel(S.flipOpposite)
     .accessibilityIdentifier("interpret.flip")
   case .listen:
    Picker(S.sourceLanguage, selection: $store.settings.interpret.listenSource) {
     ForEach(Language.sources) { Text($0.name).tag($0.code) }
    }.accessibilityIdentifier("interpret.listenSource")
    Image(systemName: "arrow.right").foregroundStyle(.secondary)
    Picker(S.targetLanguage, selection: $store.settings.interpret.listenTarget) {
     ForEach(Language.all) { Text($0.name).tag($0.code) }
    }.accessibilityIdentifier("interpret.listenTarget")
    Spacer()
   }
  }
  .disabled(session.isRunning)
 }

 @ViewBuilder private var content: some View {
  switch session.isRunning ? session.mode : store.settings.interpret.mode {
  case .conversation:
   VStack(spacing: 0) {
    half(session.farLines, live: session.farLive, label: S.opposite)
     .rotationEffect(store.settings.interpret.flipOpposite ? .degrees(180) : .zero)
     .accessibilityIdentifier("interpret.far")
    Divider()
    half(session.nearLines, live: session.nearLive, label: S.me)
     .accessibilityIdentifier("interpret.near")
   }
   .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
  case .listen:
   ScrollViewReader { proxy in
    ScrollView {
     LazyVStack(alignment: .leading, spacing: 12) {
      ForEach(session.rows) { row in
       VStack(alignment: .leading, spacing: 2) {
        if !row.original.isEmpty { Text(row.original).foregroundStyle(.secondary) }
        if !row.translation.isEmpty { Text(row.translation).font(.title3) }
       }.id(row.id)
      }
      if !session.liveOriginal.isEmpty || !session.liveTranslation.isEmpty {
       VStack(alignment: .leading, spacing: 2) {
        if !session.liveOriginal.isEmpty { Text(session.liveOriginal).foregroundStyle(.tertiary) }
        if !session.liveTranslation.isEmpty { Text(session.liveTranslation).font(.title3).foregroundStyle(.secondary) }
       }.id(-1)
      }
     }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }
    .onChange(of: session.rows.count) { proxy.scrollTo(session.rows.last?.id ?? -1, anchor: .bottom) }
   }
   .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
   .accessibilityIdentifier("interpret.listen")
  }
 }

 private func half(_ lines: [String], live: String, label: String) -> some View {
  VStack(alignment: .leading, spacing: 6) {
   Text(label).font(.caption).foregroundStyle(.secondary)
   ScrollView {
    VStack(alignment: .leading, spacing: 6) {
     ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line).font(.title3) }
     if !live.isEmpty { Text(live).font(.title3).foregroundStyle(.secondary) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
   }
   .defaultScrollAnchor(.bottom)
  }
  .padding()
  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
 }
}
