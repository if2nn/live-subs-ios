import Foundation

/// Pure PCM path from whatever ReplayKit delivers to Soniox's s16le/16 kHz/mono.
/// No AVAudioConverter: every supported layout is decoded explicitly so a wrong
/// endianness or channel layout cannot silently turn speech into noise.
/// Foundation only, so the exact shipped code runs in offline tests.
struct PCMDescriptor: Equatable, Sendable, Codable {
 var sampleRate: Double
 var channels: Int
 var bitsPerChannel: Int
 var isFloat: Bool
 var isBigEndian: Bool
 var isNonInterleaved: Bool
 var isSignedInteger: Bool
 var bytesPerFrame: Int

 /// Builds from AudioStreamBasicDescription fields (format must be lpcm).
 static func from(formatID: UInt32, sampleRate: Double, formatFlags: UInt32, bytesPerFrame: UInt32,
                  channelsPerFrame: UInt32, bitsPerChannel: UInt32) -> PCMDescriptor? {
  // 'lpcm' four-character code.
  guard formatID == 0x6C70_636D, sampleRate >= 4_000, sampleRate <= 384_000,
        channelsPerFrame >= 1, channelsPerFrame <= 16 else { return nil }
  let float = formatFlags & 0x1 != 0          // kAudioFormatFlagIsFloat
  let big = formatFlags & 0x2 != 0            // kAudioFormatFlagIsBigEndian
  let signed = formatFlags & 0x4 != 0         // kAudioFormatFlagIsSignedInteger
  let nonInterleaved = formatFlags & 0x20 != 0 // kAudioFormatFlagIsNonInterleaved
  let bits = Int(bitsPerChannel)
  let channels = Int(channelsPerFrame)
  let descriptor = PCMDescriptor(sampleRate: sampleRate, channels: channels, bitsPerChannel: bits,
   isFloat: float, isBigEndian: big, isNonInterleaved: nonInterleaved, isSignedInteger: signed,
   bytesPerFrame: Int(bytesPerFrame))
  return descriptor.isSupported ? descriptor : nil
 }
 var bytesPerSample: Int { bitsPerChannel / 8 }
 var isSupported: Bool {
  if isFloat { return bitsPerChannel == 32 || bitsPerChannel == 64 }
  return [8, 16, 24, 32].contains(bitsPerChannel)
 }
 /// Short, key-free description for diagnostics.
 var summary: String {
  "\(Int(sampleRate))Hz \(channels)ch \(bitsPerChannel)bit " + (isFloat ? "float" : (isSignedInteger ? "int" : "uint")) +
   (isBigEndian ? " BE" : " LE") + (isNonInterleaved ? " planar" : " interleaved")
 }
}

enum PCMDecoder {
 /// Reads one sample as Float in [-1, 1]. `pointer` must have bytesPerSample readable bytes.
 @inline(__always)
 static func sample(_ base: UnsafeRawPointer, _ d: PCMDescriptor) -> Float {
  switch (d.isFloat, d.bitsPerChannel) {
  case (true, 32):
   var bits = base.loadUnaligned(as: UInt32.self)
   bits = d.isBigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits)
   let v = Float(bitPattern: bits)
   return v.isFinite ? max(-1, min(1, v)) : 0
  case (true, 64):
   var bits = base.loadUnaligned(as: UInt64.self)
   bits = d.isBigEndian ? UInt64(bigEndian: bits) : UInt64(littleEndian: bits)
   let v = Double(bitPattern: bits)
   return v.isFinite ? Float(max(-1, min(1, v))) : 0
  case (false, 8):
   let raw = base.load(as: UInt8.self)
   return d.isSignedInteger ? Float(Int8(bitPattern: raw)) / 128 : (Float(raw) - 128) / 128
  case (false, 16):
   var bits = base.loadUnaligned(as: UInt16.self)
   bits = d.isBigEndian ? UInt16(bigEndian: bits) : UInt16(littleEndian: bits)
   return d.isSignedInteger ? Float(Int16(bitPattern: bits)) / 32768 : (Float(bits) - 32768) / 32768
  case (false, 24):
   let b0 = UInt32(base.load(fromByteOffset: 0, as: UInt8.self))
   let b1 = UInt32(base.load(fromByteOffset: 1, as: UInt8.self))
   let b2 = UInt32(base.load(fromByteOffset: 2, as: UInt8.self))
   var value = d.isBigEndian ? (b0 << 16 | b1 << 8 | b2) : (b2 << 16 | b1 << 8 | b0)
   if d.isSignedInteger {
    if value & 0x80_0000 != 0 { value |= 0xFF00_0000 }
    return Float(Int32(bitPattern: value)) / 8_388_608
   }
   return (Float(value) - 8_388_608) / 8_388_608
  case (false, 32):
   var bits = base.loadUnaligned(as: UInt32.self)
   bits = d.isBigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits)
   return d.isSignedInteger ? Float(Int32(bitPattern: bits)) / 2_147_483_648 : (Float(bits) - 2_147_483_648) / 2_147_483_648
  default:
   return 0
  }
 }

 /// Downmixes to mono Float. For planar layouts pass one buffer per channel;
 /// for interleaved pass one buffer. Returns nil when the buffers are too small.
 static func mono(_ buffers: [UnsafeRawBufferPointer], frames: Int, _ d: PCMDescriptor) -> [Float]? {
  guard frames > 0, d.isSupported else { return frames == 0 ? [] : nil }
  let size = d.bytesPerSample
  var out = [Float](repeating: 0, count: frames)
  let scale = 1 / Float(d.channels)
  if d.isNonInterleaved {
   guard buffers.count >= d.channels else { return nil }
   for channel in 0..<d.channels {
    let buffer = buffers[channel]
    guard let base = buffer.baseAddress, buffer.count >= frames * size else { return nil }
    for i in 0..<frames { out[i] += sample(base + i * size, d) * scale }
   }
  } else {
   guard let buffer = buffers.first, let base = buffer.baseAddress else { return nil }
   let stride = max(d.bytesPerFrame, d.channels * size)
   guard buffer.count >= (frames - 1) * stride + d.channels * size else { return nil }
   for i in 0..<frames {
    var sum: Float = 0
    for channel in 0..<d.channels { sum += sample(base + i * stride + channel * size, d) }
    out[i] = sum * scale
   }
  }
  return out
 }
}

/// Streaming box-filter resampler to 16 kHz Int16. State carries across calls,
/// so 1024-frame ReplayKit buffers do not produce clicks or drift. The box
/// average over each output period is a simple anti-alias low-pass that is
/// adequate for speech recognition.
struct SpeechResampler: Sendable {
 static let outputRate = 16_000.0
 private(set) var inputRate: Double
 private var ratio: Double
 private var consumed: Double = 0     // input samples consumed (fractional edge bookkeeping)
 private var nextEdge: Double
 private var sum: Float = 0
 private var count: Int = 0
 private var last: Float = 0
 init(inputRate: Double) {
  self.inputRate = inputRate
  ratio = inputRate / SpeechResampler.outputRate
  nextEdge = ratio
 }
 mutating func process(_ input: [Float]) -> [Int16] {
  var out: [Int16] = []
  out.reserveCapacity(Int(Double(input.count) / ratio) + 2)
  for x in input {
   sum += x; count += 1; last = x
   consumed += 1
   while consumed >= nextEdge {
    let value = count > 0 ? sum / Float(count) : last
    out.append(SpeechResampler.int16(value))
    sum = 0; count = 0
    nextEdge += ratio
   }
  }
  // Keep the counters small for very long sessions.
  if consumed > 1_000_000 { consumed -= 1_000_000; nextEdge -= 1_000_000 }
  return out
 }
 @inline(__always) static func int16(_ value: Float) -> Int16 {
  let clamped = max(-1, min(1, value))
  return Int16((clamped * 32767).rounded())
 }
}

/// Batches 16 kHz samples into ~100 ms frames and keeps level statistics.
struct SpeechChunker: Sendable {
 static let chunkSamples = 1_600
 private var pending: [Int16] = []
 private(set) var peak: Int16 = 0
 mutating func append(_ samples: [Int16]) -> [Data] {
  pending += samples
  for s in samples { let a = s == .min ? Int16.max : abs(s); if a > peak { peak = a } }
  var chunks: [Data] = []
  while pending.count >= SpeechChunker.chunkSamples {
   let slice = pending.prefix(SpeechChunker.chunkSamples)
   chunks.append(SpeechChunker.littleEndianData(slice))
   pending.removeFirst(SpeechChunker.chunkSamples)
  }
  return chunks
 }
 mutating func drain() -> Data? {
  guard !pending.isEmpty else { return nil }
  defer { pending.removeAll() }
  return SpeechChunker.littleEndianData(pending[...])
 }
 mutating func resetPeak() -> Int16 { defer { peak = 0 }; return peak }
 static func littleEndianData(_ samples: ArraySlice<Int16>) -> Data {
  var data = Data(capacity: samples.count * 2)
  for s in samples {
   let v = UInt16(bitPattern: s).littleEndian
   data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8))
  }
  return data
 }
 /// dBFS of a peak value, for diagnostics (−120 for silence).
 static func dbfs(_ peak: Int16) -> Double {
  guard peak > 0 else { return -120 }
  return 20 * log10(Double(peak) / 32767)
 }
}
