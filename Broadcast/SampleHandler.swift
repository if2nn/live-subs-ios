import ReplayKit
import AVFoundation
import CoreMedia

// ReplayKit serializes audio callbacks on its own queue. The audio pipeline
// state (descriptor, resampler, chunker) is touched only from processSampleBuffer.
// Transcript/history state is confined to client.queue. Only immutable Data
// crosses into the socket queue. Hence @unchecked Sendable with this contract.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
 private lazy var client = Soniox()
 // Audio pipeline (ReplayKit callback queue only).
 private var descriptor: PCMDescriptor?
 private var resampler: SpeechResampler?
 private var chunker = SpeechChunker()
 private var lastLevelReport = Date.distantPast
 private var consecutiveFailures = 0
 // client.queue only.
 private var transcript = Transcript()
 private var history: HistoryEntry?
 private var state = Caption()
 private var seq = 0
 private var offset = 0
 private var began = Date()
 private var lastHistoryWrite = Date.distantPast
 private var terminalStatus: String?

 override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
  CaptureIPC.extensionEntered()
  CaptureIPC.extensionDiscovered()
  CaptureIPC.event(.started)
  began = Date()
  guard Store.root != nil else {
   CaptureIPC.event(.fatal, code: 1, domain: "LiveSubs")
   finishBroadcastWithError(NSError(domain: "LiveSubs", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group 不可用，请检查 SideStore 签名"]))
   return
  }
  let keyResult = Store.keyReadResult()
  CaptureIPC.keyRead(success: keyResult.success, status: keyResult.status)
  guard keyResult.success else {
   CaptureIPC.event(.fatal, code: 2, domain: "LiveSubs")
   finishBroadcastWithError(NSError(domain: "LiveSubs", code: 2, userInfo: [NSLocalizedDescriptionKey: "请先在 Dual 里保存 Soniox Key"]))
   return
  }
  let settings = Store.sharedSettings()
  let sessionID = UUID().uuidString
  history = HistoryEntry(id: sessionID, started: began, updated: began, source: settings.languages.source, target: settings.languages.target)
  state.session = sessionID
  CaptureIPC.session(source: settings.languages.source, target: settings.languages.target, historyID: sessionID)
  _ = history.map(Store.writeHistory)

  client.onEvent = { event, code, domain in CaptureIPC.event(event, code: code, domain: domain) }
  client.onMessage = { [weak self] obj in
   guard let self, self.terminalStatus == nil else { return }
   let tokens = obj["tokens"] as? [[String: Any]]
   let arrival = max(0, Int(Date().timeIntervalSince(self.began) * 1000) - self.offset)
   if let tokens, !tokens.isEmpty { self.add(self.transcript.ingest(tokens, arrivalMS: arrival)) }
   let status = self.state.status
   self.state = self.transcript.caption
   if self.state.original.isEmpty && self.state.translated.isEmpty { self.state.status = status }
   self.publish()
   self.saveHistory(force: false)
  }
  client.onFatal = { [weak self] message in self?.fail(message) }
  client.onStatus = { [weak self] s in
   guard let self, self.terminalStatus == nil else { return }
   self.state.status = s; self.publish()
  }
  client.onReconnect = { [weak self] in
   guard let self, self.terminalStatus == nil else { return }
   // Close finalized text of the old connection; new connection restarts at 0 ms.
   self.add(self.transcript.finishFinals())
   self.saveHistory(force: true)
   let arrival = Int(Date().timeIntervalSince(self.began) * 1000)
   self.transcript = Transcript(); self.offset = arrival
  }
  state.status = "连接 Soniox…"
  client.queue.async { [self] in publish() }
  client.start(keyResult.value, config: SonioxConfig.json(settings.languages))
 }

 // client.queue only.
 private func add(_ segments: [Segment]) {
  guard !segments.isEmpty else { return }
  let shifted = segments.map { cue -> Segment in
   var absolute = cue; absolute.start += offset; absolute.end += offset; return absolute
  }
  history?.append(shifted)
 }
 private func saveHistory(force: Bool) {
  guard var entry = history else { return }
  guard force || Date().timeIntervalSince(lastHistoryWrite) > 2 else { return }
  entry.updated = Date()
  entry.pendingOriginal = transcript.source.visible
  entry.pendingTranslation = transcript.target.visible
  history = entry
  lastHistoryWrite = Date()
  if !Store.writeHistory(entry) { state.status = "历史记录写入失败" }
 }
 private func publish() {
  seq += 1
  state.seq = seq
  state.updated = Date()
  Store.publish(state)
 }
 private func fail(_ message: String) {
  guard terminalStatus == nil else { return }
  CaptureIPC.event(.fatal, code: 3, domain: "LiveSubs")
  terminalStatus = message
  add(transcript.finishFinals())
  history?.ended = Date()
  saveHistory(force: true)
  state.status = message; publish()
  client.stop()
  DispatchQueue.global().async { [self] in
   finishBroadcastWithError(NSError(domain: "LiveSubs", code: 3, userInfo: [NSLocalizedDescriptionKey: message]))
  }
 }

 override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
  guard sampleBufferType == .audioApp else { return }
  CaptureIPC.audio(frames: CMSampleBufferGetNumSamples(sampleBuffer))
  autoreleasepool { convert(sampleBuffer) }
 }

 /// ReplayKit queue only. Decodes the exact delivered layout (endianness,
 /// float/int, planar/interleaved), downmixes and resamples to 16 kHz s16le.
 private func convert(_ sample: CMSampleBuffer) {
  guard let format = CMSampleBufferGetFormatDescription(sample),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { conversionFailed(); return }
  let frames = CMSampleBufferGetNumSamples(sample)
  guard frames > 0 else { return }
  guard let d = PCMDescriptor.from(formatID: asbd.mFormatID, sampleRate: asbd.mSampleRate, formatFlags: asbd.mFormatFlags,
                                   bytesPerFrame: asbd.mBytesPerFrame, channelsPerFrame: asbd.mChannelsPerFrame,
                                   bitsPerChannel: asbd.mBitsPerChannel) else {
   CaptureIPC.audioFormat("unsupported id=\(asbd.mFormatID) flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel) ch=\(asbd.mChannelsPerFrame) rate=\(Int(asbd.mSampleRate))", supported: false)
   conversionFailed(); return
  }
  if descriptor != d {
   descriptor = d
   resampler = SpeechResampler(inputRate: d.sampleRate)
   CaptureIPC.audioFormat(d.summary, supported: true)
  }
  // Ask CoreMedia for the buffer list size, then copy references to it.
  var needed = 0
  var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed,
   bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
  guard status == noErr, needed > 0 else { conversionFailed(); return }
  let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
  defer { raw.deallocate() }
  let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
  var block: CMBlockBuffer?
  status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
   bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
   flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
  guard status == noErr else { conversionFailed(); return }
  let buffers = UnsafeMutableAudioBufferListPointer(list).map { buffer -> UnsafeRawBufferPointer in
   UnsafeRawBufferPointer(start: buffer.mData, count: Int(buffer.mDataByteSize))
  }
  guard let mono = PCMDecoder.mono(buffers, frames: frames, d), var r = resampler else { conversionFailed(); return }
  _ = block // keep the retained block alive until decoding is done
  let samples = r.process(mono)
  resampler = r
  consecutiveFailures = 0
  for chunk in chunker.append(samples) {
   let peak = chunker.resetPeak()
   if Date().timeIntervalSince(lastLevelReport) > 1 {
    lastLevelReport = Date()
    CaptureIPC.audioLevel(peakDB: SpeechChunker.dbfs(peak))
   }
   client.send(chunk, voiced: peak > 300)
  }
 }
 private func conversionFailed() {
  CaptureIPC.conversionError()
  consecutiveFailures += 1
  if consecutiveFailures == 50 {
   client.queue.async { [self] in fail("系统声音格式无法转换，广播已停止（诊断页有格式）") }
  }
 }

 override func broadcastPaused() {
  CaptureIPC.event(.paused)
  client.queue.async { [self] in state.status = "录屏已暂停"; publish() }
 }
 override func broadcastResumed() {
  CaptureIPC.event(.resumed)
  client.queue.async { [self] in state.status = "录屏已继续"; publish() }
 }
 override func broadcastFinished() {
  CaptureIPC.event(.stopped)
  // ReplayKit may end the process soon after this returns: save first, then
  // give Soniox a short, bounded chance to return final tokens.
  client.queue.sync { [self] in
   state.status = terminalStatus ?? "录屏已停止"
   saveHistory(force: true); publish()
  }
  let done = DispatchSemaphore(value: 0)
  client.finish(timeout: 1.2) { [self] _ in
   add(transcript.finishFinals())
   history?.ended = Date()
   saveHistory(force: true)
   state.status = terminalStatus ?? "录屏已停止"
   publish(); done.signal()
  }
  _ = done.wait(timeout: .now() + 1.5)
 }
}
