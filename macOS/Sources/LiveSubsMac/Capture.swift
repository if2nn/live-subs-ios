import Foundation
// macOS 15 SDK predates Sendable annotations on SCShareableContent/SCStream.
// Framework references are created, retained and controlled only by SystemAudio on MainActor;
// audio callbacks own their decoder on a separate serial queue and emit Data only.
@preconcurrency import ScreenCaptureKit
import CoreMedia
import AudioToolbox

// All mutable decoding state is confined to the serial sampleHandlerQueue.
// Only owned PCM Data crosses into the socket's queue.
final class AudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
 let queue = DispatchQueue(label: "com.aian.livesubs.mac.audio")
 let client: Soniox
 let failure: @Sendable (String) -> Void
 private var resampler: SpeechResampler?
 private var chunker = SpeechChunker()
 private var pendingStart: Date?
 private var pendingSamples = 0
 init(client: Soniox, failure: @escaping @Sendable (String) -> Void) {
  self.client = client; self.failure = failure
 }
 func stream(_ stream: SCStream, didStopWithError error: Error) {
  failure("系统音频采集已停止（\((error as NSError).code)）")
 }
 func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
  guard type == .audio, sample.isValid, let format = sample.formatDescription,
   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
   let d = PCMDescriptor.from(formatID: asbd.mFormatID, sampleRate: asbd.mSampleRate,
    formatFlags: asbd.mFormatFlags, bytesPerFrame: asbd.mBytesPerFrame,
    channelsPerFrame: asbd.mChannelsPerFrame, bitsPerChannel: asbd.mBitsPerChannel) else { return }
  let frames = CMSampleBufferGetNumSamples(sample)
  guard frames > 0 else { return }
  if resampler?.inputRate != d.sampleRate { resampler = SpeechResampler(inputRate: d.sampleRate) }
  var needed = 0
  _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed,
   bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
   flags: 0, blockBufferOut: nil)
  guard needed > 0 else { return }
  let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
  defer { raw.deallocate() }
  let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
  var block: CMBlockBuffer?
  let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
   bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
   flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
  guard status == noErr else { return }
  withExtendedLifetime(block) {
   let buffers = UnsafeMutableAudioBufferListPointer(list).map {
    UnsafeRawBufferPointer(start: $0.mData, count: Int($0.mDataByteSize))
   }
   guard let mono = PCMDecoder.mono(buffers, frames: frames, d), var r = resampler else { return }
   let samples = r.process(mono); resampler = r
   // PTS and host clock share the capture clock. Map sample start to wall time,
   // carrying the oldest sample timestamp across 100 ms chunk boundaries.
   let pts = CMSampleBufferGetPresentationTimeStamp(sample)
   let delta = CMTimeGetSeconds(CMTimeSubtract(pts, CMClockGetTime(CMClockGetHostTimeClock())))
   let sampleStart = Date().addingTimeInterval(delta.isFinite ? delta : -Double(frames) / d.sampleRate)
   if pendingSamples == 0 { pendingStart = sampleStart }
   pendingSamples += samples.count
   for chunk in chunker.append(samples) {
    client.send(chunk, voiced: chunker.resetPeak() > 300, capturedAt: pendingStart ?? sampleStart)
    pendingStart = (pendingStart ?? sampleStart).addingTimeInterval(Double(chunk.count) / 32000)
    pendingSamples -= chunk.count / 2
   }
  }
 }
 func drain() async {
  await withCheckedContinuation { continuation in
   queue.async { [self] in
    if let data = chunker.drain() { client.send(data, voiced: true, capturedAt: pendingStart ?? Date()) }
    pendingStart = nil; pendingSamples = 0
    continuation.resume()
   }
  }
 }
}

@MainActor
final class SystemAudio {
 private var stream: SCStream?
 private var output: AudioOutput?
 func start(client: Soniox, failure: @escaping @Sendable (String) -> Void) async throws {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  guard let display = content.displays.first else { throw CaptureFailure.noDisplay }
  let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
  let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
  let configuration = SCStreamConfiguration()
  configuration.capturesAudio = true
  configuration.excludesCurrentProcessAudio = true
  configuration.sampleRate = 16000; configuration.channelCount = 1
  // No screen output is registered or persisted. A tiny surface avoids video overhead.
  configuration.width = 2; configuration.height = 2
  configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
  let output = AudioOutput(client: client, failure: failure)
  let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
  try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
  self.output = output; self.stream = stream
  do { try await stream.startCapture() } catch {
   self.stream = nil; self.output = nil; throw error
  }
 }
 func stop() async throws {
  let old = stream; let decoder = output
  stream = nil; output = nil
  do { if let old { try await old.stopCapture() } }
  catch { await decoder?.drain(); throw error }
  await decoder?.drain()
 }
 enum CaptureFailure: LocalizedError {
  case noDisplay
  var errorDescription: String? { "没有找到可采集的显示器" }
 }
}
