import Foundation

/// Behavior tests for the exact shipped audio path, settings, Soniox request
/// and history logic. Foundation only: runs on any Swift toolchain.
@main @MainActor struct FeatureTests {
 static var checks = 0
 static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message); checks += 1
 }

 /// Builds `frames` of a sine at `hz` in the requested layout.
 static func pcm(_ d: PCMDescriptor, frames: Int, hz: Double, amplitude: Double = 0.5) -> [Data] {
  let size = d.bytesPerSample
  func encode(_ v: Double) -> [UInt8] {
   if d.isFloat && size == 4 {
    let bits = Float(v).bitPattern
    let ordered = d.isBigEndian ? bits.bigEndian : bits.littleEndian
    return withUnsafeBytes(of: ordered) { Array($0) }
   }
   if d.isFloat && size == 8 {
    let bits = v.bitPattern
    let ordered = d.isBigEndian ? bits.bigEndian : bits.littleEndian
    return withUnsafeBytes(of: ordered) { Array($0) }
   }
   if size == 2 {
    let raw = UInt16(bitPattern: Int16((v * 32767).rounded()))
    let ordered = d.isBigEndian ? raw.bigEndian : raw.littleEndian
    return withUnsafeBytes(of: ordered) { Array($0) }
   }
   if size == 3 {
    let raw = UInt32(bitPattern: Int32((v * 8_388_607).rounded())) & 0xFF_FFFF
    let b = [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF)]
    return d.isBigEndian ? b.reversed() : b
   }
   let raw = UInt32(bitPattern: Int32((v * 2_147_483_647).rounded()))
   let ordered = d.isBigEndian ? raw.bigEndian : raw.littleEndian
   return withUnsafeBytes(of: ordered) { Array($0) }
  }
  if d.isNonInterleaved {
   return (0..<d.channels).map { _ in
    var data = Data()
    for i in 0..<frames { data.append(contentsOf: encode(amplitude * sin(2 * .pi * hz * Double(i) / d.sampleRate))) }
    return data
   }
  }
  var data = Data()
  for i in 0..<frames {
   let v = amplitude * sin(2 * .pi * hz * Double(i) / d.sampleRate)
   for _ in 0..<d.channels { data.append(contentsOf: encode(v)) }
  }
  return [data]
 }

 static func run(_ d: PCMDescriptor, seconds: Double = 1, hz: Double = 440, chunk: Int = 1024) -> [Int16] {
  let total = Int(d.sampleRate * seconds)
  let buffers = pcm(d, frames: total, hz: hz)
  var resampler = SpeechResampler(inputRate: d.sampleRate)
  var out: [Int16] = []
  var start = 0
  while start < total {
   let n = min(chunk, total - start)
   let slices: [Data]
   if d.isNonInterleaved { slices = buffers.map { $0.subdata(in: start * d.bytesPerSample..<(start + n) * d.bytesPerSample) } }
   else { slices = [buffers[0].subdata(in: start * d.bytesPerFrame..<(start + n) * d.bytesPerFrame)] }
   let mono: [Float]? = withExtendedLifetime(slices) {
    var pointers: [UnsafeRawBufferPointer] = []
    var copies: [UnsafeMutableRawBufferPointer] = []
    for s in slices {
     let m = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, s.count), alignment: 16)
     s.copyBytes(to: m); copies.append(m); pointers.append(UnsafeRawBufferPointer(start: m.baseAddress, count: s.count))
    }
    defer { copies.forEach { $0.deallocate() } }
    return PCMDecoder.mono(pointers, frames: n, d)
   }
   check(mono != nil, "decode \(d.summary)")
   out += resampler.process(mono!)
   start += n
  }
  return out
 }
 static func zeroCrossings(_ s: [Int16]) -> Int {
  var count = 0
  for i in 1..<s.count where (s[i - 1] < 0) != (s[i] < 0) { count += 1 }
  return count
 }
 static func peak(_ s: [Int16]) -> Int { s.map { abs(Int($0)) }.max() ?? 0 }

 static func descriptor(rate: Double, ch: Int, bits: Int, float: Bool, big: Bool, planar: Bool) -> PCMDescriptor {
  var flags: UInt32 = 0
  if float { flags |= 0x1 } else { flags |= 0x4 }
  if big { flags |= 0x2 }
  if planar { flags |= 0x20 }
  let bytesPerFrame = planar ? bits / 8 : bits / 8 * ch
  return PCMDescriptor.from(formatID: 0x6C70_636D, sampleRate: rate, formatFlags: flags, bytesPerFrame: UInt32(bytesPerFrame),
   channelsPerFrame: UInt32(ch), bitsPerChannel: UInt32(bits))!
 }

 static func main() throws {
  // 1) Every layout ReplayKit is known or likely to deliver decodes to a clean 440 Hz tone.
  let layouts: [PCMDescriptor] = [
   descriptor(rate: 44_100, ch: 2, bits: 16, float: false, big: true, planar: false),   // classic audioApp: BE int16 stereo
   descriptor(rate: 48_000, ch: 2, bits: 16, float: false, big: false, planar: false),
   descriptor(rate: 48_000, ch: 1, bits: 16, float: false, big: true, planar: false),
   descriptor(rate: 48_000, ch: 2, bits: 32, float: true, big: false, planar: true),    // AVAudio standard planar float
   descriptor(rate: 44_100, ch: 2, bits: 32, float: true, big: false, planar: false),
   descriptor(rate: 48_000, ch: 2, bits: 24, float: false, big: false, planar: false),
   descriptor(rate: 48_000, ch: 2, bits: 32, float: false, big: true, planar: true),
   descriptor(rate: 16_000, ch: 1, bits: 16, float: false, big: false, planar: false),
   descriptor(rate: 48_000, ch: 2, bits: 64, float: true, big: false, planar: false)
  ]
  for d in layouts {
   let out = run(d)
   check(abs(out.count - 16_000) <= 2, "16 kHz output count for \(d.summary): \(out.count)")
   let crossings = zeroCrossings(out)
   check(abs(crossings - 880) <= 6, "440 Hz preserved for \(d.summary): \(crossings) crossings")
   let p = peak(out)
   check(p > 14_000 && p < 17_500, "amplitude preserved for \(d.summary): \(p)")
  }
  // The preview 3 failure class: big-endian data read as little-endian is noise, not a tone.
  let be = descriptor(rate: 44_100, ch: 2, bits: 16, float: false, big: true, planar: false)
  var wrong = be; wrong.isBigEndian = false
  let raw = pcm(be, frames: 44_100, hz: 440)
  let misread = raw[0].withUnsafeBytes { PCMDecoder.mono([$0], frames: 44_100, wrong)! }
  var r = SpeechResampler(inputRate: 44_100)
  check(abs(zeroCrossings(r.process(misread)) - 880) > 200, "endianness mismatch is detectable as noise")
  // Odd ratios and chunk sizes do not drift.
  let odd = run(descriptor(rate: 44_100, ch: 2, bits: 16, float: false, big: true, planar: false), seconds: 3, chunk: 941)
  check(abs(odd.count - 48_000) <= 2, "no drift over 3 s with odd chunks: \(odd.count)")
  // Unsupported formats are rejected, not guessed.
  check(PCMDescriptor.from(formatID: 0x6161_6320, sampleRate: 44_100, formatFlags: 0, bytesPerFrame: 0, channelsPerFrame: 2, bitsPerChannel: 0) == nil, "AAC rejected")
  check(PCMDescriptor.from(formatID: 0x6C70_636D, sampleRate: 44_100, formatFlags: 0x1, bytesPerFrame: 4, channelsPerFrame: 2, bitsPerChannel: 16) == nil, "float16 rejected")
  check(PCMDecoder.mono([UnsafeRawBufferPointer(start: nil, count: 0)], frames: 10, layouts[0]) == nil, "short buffer rejected")
  check(layouts[0].summary == "44100Hz 2ch 16bit int BE interleaved", layouts[0].summary)

  // 2) Chunker: 100 ms little-endian frames, peak tracking, drain.
  var chunker = SpeechChunker()
  let samples: [Int16] = (0..<4000).map { Int16(truncatingIfNeeded: $0 % 2 == 0 ? $0 : -$0) }
  let chunks = chunker.append(samples)
  check(chunks.count == 2 && chunks.allSatisfy { $0.count == 3200 }, "two 100 ms chunks")
  check(chunks[0][4] == 2 && chunks[0][5] == 0 && chunks[0][2] == 0xFF, "little-endian bytes")
  check(chunker.peak == 3999, "peak tracked")
  check(chunker.drain()?.count == 800 * 2, "drain remainder")
  check(SpeechChunker.dbfs(0) == -120 && abs(SpeechChunker.dbfs(32767)) < 0.01, "dBFS")
  check(SpeechResampler.int16(2) == 32767 && SpeechResampler.int16(-2) == -32767, "clamped")

  // 3) Soniox start request follows the chosen languages; never contains a key.
  var auto = LanguageSettings(); auto.source = "auto"; auto.target = "zh"
  let a = SonioxConfig.dictionary(auto)
  check(a["model"] as? String == "stt-rt-v6" && a["audio_format"] as? String == "s16le", "model/format")
  check(a["sample_rate"] as? Int == 16_000 && a["num_channels"] as? Int == 1, "rate/channels")
  check((a["translation"] as? [String: String]) == ["type": "one_way", "target_language": "zh"], "one-way zh")
  check((a["language_hints"] as? [String])?.first == "zh", "auto hints start with target")
  check(a["api_key"] == nil && !SonioxConfig.json(auto).contains("key"), "no key in start request")
  var fixed = LanguageSettings(); fixed.source = "ja"; fixed.target = "en"
  let f = SonioxConfig.dictionary(fixed)
  check((f["language_hints"] as? [String]) == ["ja"], "fixed source hint")
  check((f["translation"] as? [String: String])?["target_language"] == "en", "target en")
  var same = LanguageSettings(); same.source = "zh"; same.target = "zh"
  check(SonioxConfig.dictionary(same)["translation"] == nil && !same.translates, "same language: transcription only")
  var bogus = LanguageSettings(); bogus.source = "xx"; bogus.target = "auto"
  check(bogus.normalized() == LanguageSettings(), "invalid languages fall back")
  check(SonioxConfig.json(auto).hasPrefix("{"), "json text")

  // 4) Settings persistence and clamping.
  var settings = AppSettings()
  settings.display = .translationOnly
  settings.style.fontSize = 99; settings.style.lines = 9; settings.style.backgroundOpacity = 0
  settings.style.translationFirst = true; settings.style.position = .top; settings.style.translationColor = .yellow
  let decoded = AppSettings.decode(settings.encoded())
  check(decoded.display == .translationOnly && decoded.style.translationFirst && decoded.style.position == .top, "settings round trip")
  check(decoded.style.fontSize == 48 && decoded.style.lines == 4 && decoded.style.backgroundOpacity == 0.3, "settings clamped")
  check(decoded.style.translationColor == .yellow, "color kept")
  check(AppSettings.decode(Data("garbage".utf8)) == AppSettings(), "bad data defaults")
  check(AppSettings.decode(nil) == AppSettings(), "nil defaults")
  check(DisplayMode.allCases.map(\.title) == ["双语", "仅译文", "仅原文"], "display titles")
  check(Language.name("auto") == "自动识别" && Language.name("ja") == "日语", "language names")

  // 5) History: rows, exports, codec, bounds.
  var entry = HistoryEntry(id: "ABC-123", started: Date(timeIntervalSince1970: 1_800_000_000), updated: Date(timeIntervalSince1970: 1_800_000_000), source: "en", target: "zh")
  entry.append([Segment(lane: .original, text: " Hello there. ", start: 1000, end: 2000, approximate: false),
                Segment(lane: .translation, text: "你好。", start: 2100, end: 2100, approximate: true),
                Segment(lane: .translation, text: "欢迎。", start: 2200, end: 2200, approximate: true),
                Segment(lane: .original, text: "Second line", start: 5000, end: 6000, approximate: false),
                Segment(lane: .original, text: "   ", start: 7000, end: 7000, approximate: false)])
  check(entry.lines.count == 4, "blank text dropped")
  let rows = entry.rows
  check(rows.count == 2 && rows[0].original == "Hello there." && rows[0].translation == "你好。欢迎。", "translations join their original, CJK without spaces")
  check(rows[1].translation.isEmpty, "untranslated row allowed")
  check(entry.plainText(.translationOnly) == "[00:01] 你好。欢迎。", entry.plainText(.translationOnly))
  check(entry.plainText(.bilingual).contains("[00:05]\nSecond line"), "bilingual text")
  let srt = entry.srt(.bilingual)
  check(srt.hasPrefix("1\n00:00:01,000 --> 00:00:05,000\nHello there.\n你好。欢迎。\n\n2\n00:00:05,000 --> 00:00:09,000\nSecond line"), srt)
  check(!entry.srt(.translationOnly).contains("Second line"), "translation-only skips untranslated")
  let roundTrip = HistoryEntry.decode(entry.encoded()!)
  check(roundTrip == entry, "history codec")
  var unsafe = entry; unsafe.id = "../x"
  check(HistoryEntry.decode(unsafe.encoded()!) == nil, "unsafe id rejected")
  check(HistoryEntry.clock(3_725_000) == "1:02:05" && HistoryEntry.clock(65_000) == "01:05", "clock")
  check(HistoryEntry.joiner("Hello", "world") == " " && HistoryEntry.joiner("你好", "世界") == "", "joiner")
  var big = HistoryEntry(id: "BIG", started: Date(), updated: Date(), source: "en", target: "zh")
  big.append((0..<(HistoryEntry.maximumLines + 10)).map { Segment(lane: .original, text: "x\($0)", start: $0, end: $0, approximate: false) })
  check(big.lines.count == HistoryEntry.maximumLines && big.lines.first?.text == "x10", "history bounded")

  // 6) Rolling caption context for multi-line display.
  var t = Transcript()
  func tok(_ text: String, _ lane: String = "original", _ final: Bool = true) -> [String: Any] {
   ["text": text, "translation_status": lane, "is_final": final, "start_ms": 0, "end_ms": 100]
  }
  _ = t.ingest([tok("First sentence."), tok("<end>"), tok("第一句。", "translation"), tok("<end>", "translation")])
  _ = t.ingest([tok("Second", "original", false), tok("第二", "translation", false)])
  check(t.caption.original == "First sentence. Second", t.caption.original)
  check(t.caption.translated == "第一句。第二", t.caption.translated)
  check(Transcript.rolling(String(repeating: "a", count: 400), "b").count == 320, "rolling bounded")
  check(t.caption.originalLive == "Second" && t.caption.translatedLive == "第二", "live sentence is the partial")
  _ = t.ingest([tok("Second done."), tok("<end>")])
  check(t.caption.originalLive == "Second done.", "after endpoint the last sentence stays live")
  let old = try JSONDecoder().decode(Caption.self, from: Data(#"{"original":"a","translated":"b","status":"s","updated":0,"seq":1,"session":""}"#.utf8))
  check(old.originalLive == nil, "older caption files still decode")

  // 7) Caption window geometry and render size (preview 5: sharp; strip shape optional).
  var strip = AppSettings(); strip.pipShape = .strip
  let classic = AppSettings()
  check(classic.pipShape == .classic, "classic (preview 4) shape stays the default")
  let c3 = CaptionCanvas.make(screenScale: 3, settings: strip)
  check(c3.pixelWidth == 1440 && c3.pixelHeight == 336 && c3.scale == 3, "strip at 3x renders 1440x336 (480x112 pt)")
  let c2 = CaptionCanvas.make(screenScale: 2, settings: strip)
  check(c2.pixelWidth == 960 && c2.pixelHeight == 224 && c2.scale == 2, "strip at 2x renders 960x224")
  check(CaptionCanvas.aspect(for: strip) > 4 && CaptionCanvas.aspect(for: strip) > CaptionCanvas.aspect(for: classic), "strip is wider and flatter than classic")
  check(CaptionCanvas.make(screenScale: .nan, settings: strip).pixelWidth == 1440, "unknown scale falls back to 3x")
  check(c3.label == "1440x336 @3x", c3.label)
  let k3 = CaptionCanvas.make(screenScale: 3, settings: classic)
  check(k3.pixelWidth == 1440 && k3.scale == 3, "classic is also drawn at screen scale: \(k3.label)")
  check(k3.pointHeight == CaptionCanvas.pointHeight(for: classic) && k3.pointHeight != CaptionCanvas.stripPointHeight, "classic keeps its own height")
  check(k3.pixelWidth != 1280, "no longer the fixed 1280 px preview 4 frame")
  // Classic height still follows font size, line count and display mode (preview 4 behaviour).
  var bigger = classic; bigger.style.fontSize = 40
  var fewer = classic; fewer.style.lines = 1
  var single = classic; single.display = .translationOnly
  check(CaptionCanvas.pointHeight(for: bigger) > CaptionCanvas.pointHeight(for: classic), "classic grows with font")
  check(CaptionCanvas.pointHeight(for: fewer) < CaptionCanvas.pointHeight(for: classic), "classic shrinks with fewer lines")
  check(CaptionCanvas.pointHeight(for: single) < CaptionCanvas.pointHeight(for: classic), "classic single lane is shorter")
  var maxed = classic; maxed.style.fontSize = 48; maxed.style.lines = 4
  check(CaptionCanvas.classicPointRange.contains(CaptionCanvas.pointHeight(for: maxed)), "classic height clamped")
  var smallStrip = strip; smallStrip.style.fontSize = 18; smallStrip.style.lines = 1
  check(CaptionCanvas.pointHeight(for: smallStrip) == 112, "strip height is fixed")
  // PiP render size: match the pixels the aspect-fit frame occupies, 1:1.
  let wide = CaptionCanvas.make(screenScale: 3, settings: strip, renderSize: (width: 1080, height: 600))
  check(wide.pixelWidth == 1080 && wide.pixelHeight == 252, "width-limited PiP window: \(wide.label)")
  let tall = CaptionCanvas.make(screenScale: 3, settings: strip, renderSize: (width: 2000, height: 300))
  check(tall.pixelWidth == 1284 && tall.pixelHeight <= 300, "height-limited PiP window: \(tall.label)")
  let huge = CaptionCanvas.make(screenScale: 3, settings: strip, renderSize: (width: 9000, height: 9000))
  check(huge.pixelWidth == CaptionCanvas.maxPixelWidth && huge.pixelHeight == 560, "render size clamped: \(huge.label)")
  let tiny = CaptionCanvas.make(screenScale: 3, settings: strip, renderSize: (width: 100, height: 40))
  check(tiny.pixelWidth == CaptionCanvas.minPixelWidth, "render size floor")
  for w in [1, 333, 1081, 1279, 1441, 2399] {
   let c = CaptionCanvas.make(screenScale: 3, settings: strip, renderSize: (width: w, height: 5000))
   check(c.pixelWidth % 2 == 0 && c.pixelHeight % 2 == 0 && abs(Double(c.pixelWidth) / Double(c.pixelHeight) - c.aspect) < 0.05, "even strip buffer for \(w): \(c.label)")
   let k = CaptionCanvas.make(screenScale: 3, settings: classic, renderSize: (width: w, height: 5000))
   check(k.pixelWidth % 2 == 0 && k.pixelHeight % 2 == 0 && abs(Double(k.pixelWidth) / Double(k.pixelHeight) - k.aspect) < 0.05, "classic buffer for \(w): \(k.label)")
  }
  let kr = CaptionCanvas.make(screenScale: 3, settings: classic, renderSize: (width: 1000, height: 200))
  check(Double(kr.pixelHeight) <= 200 && kr.pixelWidth <= 1000, "classic fits the PiP render size: \(kr.label)")

  // Typography: what fits each shape.
  for shape in PiPShape.allCases {
   for display in DisplayMode.allCases {
    for font in [18.0, 30.0, 48.0] {
     for lines in [1, 2, 4] {
      for notice in [false, true] {
       var st = AppSettings(); st.pipShape = shape; st.display = display; st.style.fontSize = font; st.style.lines = lines
       let t = CaptionTypography.make(st, hasNotice: notice, hasCaption: true)
       let budget = CaptionCanvas.pointHeight(for: st) - 2 * CaptionTypography.verticalPadding
       check(t.lines >= 1 && t.lines <= lines && t.textHeight(display: display) + t.noticeHeight <= budget + 0.5,
             "\(shape) \(display) font \(font) lines \(lines) notice \(notice) fits: \(t)")
      }
     }
    }
   }
  }
  let tDefault = CaptionTypography.make(strip, hasNotice: false, hasCaption: true)
  check(tDefault.mainPoints == 22.5 && abs(tDefault.secondaryPoints - 17.55) < 0.001, "default 22.5/17.55 pt")
  check(tDefault.lines == 1 && tDefault.textHeight(display: .bilingual) <= 112 - 20, "strip default bilingual: one translation + one original line, got \(tDefault.lines)")
  check(CaptionTypography.make(strip, hasNotice: true, hasCaption: true).lines == 1, "strip keeps both lanes with a footnote")
  check(CaptionTypography.make(classic, hasNotice: true, hasCaption: true).lines == classic.style.lines, "classic shows the chosen lines")
  var stripOnly = strip; stripOnly.display = .translationOnly; stripOnly.style.lines = 4
  check(CaptionTypography.make(stripOnly, hasNotice: false, hasCaption: true).lines >= 3, "strip translation-only uses the height")
  let empty = CaptionTypography.make(AppSettings(), hasNotice: true, hasCaption: false)
  check(empty.noticeHeight == 0 && empty.noticePoints >= 14, "empty window: centred, legible message")

  // Settings: the new shape persists; older saved settings decode without resetting.
  var saved = AppSettings(); saved.pipShape = .strip; saved.style.fontSize = 36
  check(AppSettings.decode(saved.encoded()) == saved.normalized(), "shape round-trips")
  let preview4 = #"{"languages":{"source":"auto","target":"zh"},"display":"translationOnly","style":{"fontSize":36,"lines":3,"translationColor":"yellow","originalColor":"white","position":"bottom","translationFirst":true,"backgroundOpacity":1}}"#
  let migrated = AppSettings.decode(Data(preview4.utf8))
  check(migrated.pipShape == .classic && migrated.display == .translationOnly && migrated.style.fontSize == 36 && migrated.style.lines == 3, "preview 4 settings keep values, default to classic")

  // Preview 6: appearance follows the system by default; older settings migrate to it.
  check(AppSettings().appearance == .system, "appearance defaults to system")
  check(migrated.appearance == .system, "preview 4 settings default to system appearance")
  let preview5 = #"{"languages":{"source":"en","target":"zh"},"display":"bilingual","pipShape":"strip","style":{"fontSize":30,"lines":2,"translationColor":"white","originalColor":"gray","position":"bottom","translationFirst":false,"backgroundOpacity":1}}"#
  let migrated5 = AppSettings.decode(Data(preview5.utf8))
  check(migrated5.appearance == .system && migrated5.pipShape == .strip && migrated5.languages.source == "en", "preview 5 settings keep values, default to system appearance")
  for mode in AppearanceMode.allCases {
   var a = AppSettings(); a.appearance = mode
   check(AppSettings.decode(a.encoded()).appearance == mode, "appearance \(mode.rawValue) round-trips")
  }
  check(AppearanceMode.allCases.map(\.title) == ["跟随系统", "浅色", "深色"], "appearance titles")
  var badAppearance = #"{"appearance":"sepia","pipShape":"strip"}"#
  check(AppSettings.decode(Data(badAppearance.utf8)).appearance == .system && AppSettings.decode(Data(badAppearance.utf8)).pipShape == .strip, "unknown appearance falls back without resetting others")
  badAppearance = ""

  print("FeatureTests PASS (\(checks) checks: audio decode/resample, Soniox config, settings, appearance, history, captions, caption window geometry)")
 }
}
