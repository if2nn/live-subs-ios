import UIKit
import CoreMedia
import CoreVideo

/// Draws the caption strip into IOSurface-backed 32BGRA pixel buffers.
///
/// Preview 3 used non-IOSurface 32ARGB buffers, which a device video layer may
/// accept for enqueue yet never present (readyForDisplay stayed 0).
/// The PiP canvas is always opaque black (system PiP windows cannot be transparent).
///
/// Preview 5 sharpness changes (Ian: preview 4 text was very blurry at 1280×404):
/// - layout in points on a 480 pt-wide canvas (`CaptionCanvas`: the classic
///   shape, or the optional 480×160 pt strip), rasterised at the screen scale
///   (1440 px wide on a 3x iPhone) and, once AVKit reports the
///   PiP render size, at exactly the pixels the frame occupies there, so the
///   compositor does not resample the text;
/// - no black stroke and no blurred shadow: on a black canvas they only ate into
///   glyph edges and softened them;
/// - fixed line heights so CJK fallback fonts do not change the layout;
/// - antialiasing with subpixel glyph positioning, no font smoothing.
@MainActor
final class CaptionRenderer {
 struct Content: Equatable {
  var original: String
  var translated: String
  var originalLive = ""
  var translatedLive = ""
  var notice: String
  var settings: AppSettings
 }

 /// Display scale of the screen showing the app (set from the trait collection).
 var screenScale: Double = 3 { didSet { if screenScale != oldValue { pool = nil } } }
 /// PiP render size reported by AVKit, in pixels; nil when PiP is not showing.
 var renderSize: (width: Int, height: Int)? = nil
 private(set) var lastCanvas: CaptionCanvas?
 #if DEBUG
 /// UI tests only: receives the first frame of each canvas size as PNG data.
 var debugFrameSink: ((CaptionCanvas, Data) -> Void)?
 private var exportedSizes: Set<String> = []
 #endif

 private var pool: CVPixelBufferPool?
 private var poolCanvas: CaptionCanvas?

 func canvas(for settings: AppSettings) -> CaptionCanvas {
  CaptionCanvas.make(screenScale: screenScale, settings: settings, renderSize: renderSize)
 }

 private func buffer(_ canvas: CaptionCanvas) -> CVPixelBuffer? {
  if pool == nil || poolCanvas != canvas {
   let attributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: canvas.pixelWidth,
    kCVPixelBufferHeightKey as String: canvas.pixelHeight,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
   ]
   var created: CVPixelBufferPool?
   CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                           attributes as CFDictionary, &created)
   pool = created; poolCanvas = canvas
  }
  guard let pool else { return nil }
  var out: CVPixelBuffer?
  guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess else { return nil }
  return out
 }

 static func uiColor(_ c: CaptionColor) -> UIColor {
  let (r, g, b) = c.rgb
  return UIColor(red: r, green: g, blue: b, alpha: 1)
 }

 /// Keeps the end of `text` that fits in `lines` lines (newest words win).
 static func fit(_ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat, lines: Int, lineHeight: CGFloat) -> String {
  let limit = lineHeight * CGFloat(lines) + 1
  func height(_ s: String) -> CGFloat {
   (s as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
    options: [.usesLineFragmentOrigin], attributes: attributes, context: nil).height
  }
  if text.isEmpty || height(text) <= limit { return text }
  let chars = Array(text)
  var lo = 0, hi = chars.count
  while lo < hi {
   let mid = (lo + hi) / 2
   if height(String(chars[mid...])) <= limit { hi = mid } else { lo = mid + 1 }
  }
  return String(chars[lo...]).trimmingCharacters(in: .whitespaces)
 }

 /// Lyric-style emphasis: the live sentence at full color, earlier context dimmed.
 static func lyric(_ text: String, live: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
  let out = NSMutableAttributedString(string: text, attributes: attributes)
  let liveTrimmed = live.trimmingCharacters(in: .whitespaces)
  guard !liveTrimmed.isEmpty, let color = attributes[.foregroundColor] as? UIColor else { return out }
  let ns = text as NSString
  let range = ns.range(of: liveTrimmed, options: .backwards)
  let liveStart = range.location == NSNotFound ? max(0, ns.length - (liveTrimmed as NSString).length) : range.location
  if liveStart > 0 {
   out.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.5), range: NSRange(location: 0, length: liveStart))
  }
  return out
 }

 private static func paragraph(lineHeight: CGFloat) -> NSParagraphStyle {
  let p = NSMutableParagraphStyle()
  p.alignment = .center
  p.lineBreakMode = .byWordWrapping
  p.minimumLineHeight = lineHeight
  p.maximumLineHeight = lineHeight
  return p
 }

 func render(_ content: Content) -> CVPixelBuffer? {
  let settings = content.settings.normalized()
  let s = settings.style
  let canvas = canvas(for: settings)
  guard let pixel = buffer(canvas) else { return nil }
  CVPixelBufferLockBaseAddress(pixel, [])
  defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
  guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: canvas.pixelWidth, height: canvas.pixelHeight,
   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
   space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
  context.setFillColor(UIColor.black.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: canvas.pixelWidth, height: canvas.pixelHeight))
  context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
  context.setAllowsFontSubpixelPositioning(true); context.setShouldSubpixelPositionFonts(true)
  context.setAllowsFontSmoothing(false); context.setShouldSmoothFonts(false)
  // UIKit coordinates in points: flip, then scale points → pixels.
  context.translateBy(x: 0, y: CGFloat(canvas.pixelHeight)); context.scaleBy(x: 1, y: -1)
  context.scaleBy(x: CGFloat(canvas.scale), y: CGFloat(canvas.scale))
  UIGraphicsPushContext(context)
  defer { UIGraphicsPopContext() }

  let W = CGFloat(CaptionCanvas.pointWidth), H = CGFloat(canvas.pointHeight)
  let hasCaptionText: Bool
  switch settings.display {
  case .originalOnly: hasCaptionText = !content.original.isEmpty
  case .translationOnly: hasCaptionText = !content.translated.isEmpty
  case .bilingual: hasCaptionText = !(content.translated.isEmpty && content.original.isEmpty)
  }
  let type = CaptionTypography.make(settings, hasNotice: !content.notice.isEmpty, hasCaption: hasCaptionText)
  let width = W - 2 * CGFloat(CaptionTypography.horizontalPadding)
  let x = CGFloat(CaptionTypography.horizontalPadding)

  func attrs(_ points: Double, weight: UIFont.Weight, _ color: CaptionColor) -> ([NSAttributedString.Key: Any], CGFloat) {
   let lh = CGFloat(CaptionTypography.lineHeight(points))
   return ([.font: UIFont.systemFont(ofSize: CGFloat(points), weight: weight), .foregroundColor: Self.uiColor(color),
            .paragraphStyle: Self.paragraph(lineHeight: lh)], lh)
  }
  struct Block { var text: String; var live: String; var attributes: [NSAttributedString.Key: Any]; var lineHeight: CGFloat }
  let (oAttrs, oLH) = settings.display == .originalOnly
   ? attrs(type.secondaryPoints, weight: .semibold, s.originalColor)
   : attrs(type.secondaryPoints, weight: .medium, s.originalColor)
  let (tAttrs, tLH) = attrs(type.mainPoints, weight: .semibold, s.translationColor)
  let original = Block(text: content.original, live: content.originalLive, attributes: oAttrs, lineHeight: oLH)
  let translated = Block(text: content.translated, live: content.translatedLive, attributes: tAttrs, lineHeight: tLH)
  let blocks: [Block]
  switch settings.display {
  case .originalOnly: blocks = [original]
  case .translationOnly: blocks = [translated]
  case .bilingual: blocks = s.translationFirst ? [translated, original] : [original, translated]
  }
  let fitted = blocks.map { b -> (String, Block) in
   (Self.fit(b.text, attributes: b.attributes, width: width, lines: type.lines, lineHeight: b.lineHeight), b)
  }
  let measured = fitted.map { pair -> CGFloat in
   pair.0.isEmpty ? 0 : min((pair.0 as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
    options: [.usesLineFragmentOrigin], attributes: pair.1.attributes, context: nil).height.rounded(.up),
    pair.1.lineHeight * CGFloat(type.lines))
  }
  let shown = measured.filter { $0 > 0 }.count
  let gap = CGFloat(CaptionTypography.laneGap)
  let total = measured.reduce(0, +) + gap * CGFloat(max(0, shown - 1))
  let pad = CGFloat(CaptionTypography.verticalPadding)
  let available = H - 2 * pad - CGFloat(type.noticeHeight)
  var y: CGFloat
  switch s.position {
  case .top: y = pad
  case .center: y = pad + max(0, (available - total) / 2)
  case .bottom: y = pad + max(0, available - total)
  }
  for (index, pair) in fitted.enumerated() where !pair.0.isEmpty {
   let h = measured[index]
   Self.lyric(pair.0, live: pair.1.live, attributes: pair.1.attributes)
    .draw(with: CGRect(x: x, y: y.rounded(), width: width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
   y += h + gap
  }
  if !content.notice.isEmpty {
   // A footnote under live captions, or the centred message of an empty window.
   let footnote = shown > 0
   let (nAttrs, nLH) = attrs(type.noticePoints, weight: .medium, s.translationColor)
   var noticeAttrs = nAttrs
   noticeAttrs[.foregroundColor] = UIColor(white: footnote ? 0.6 : 0.82, alpha: 1)
   let rect = footnote
    ? CGRect(x: x, y: H - pad - CGFloat(type.noticeHeight) + 2, width: width, height: nLH)
    : CGRect(x: x, y: ((H - nLH * 2) / 2).rounded(), width: width, height: nLH * 2)
   (content.notice as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: noticeAttrs, context: nil)
  }
  lastCanvas = canvas
  #if DEBUG
  if let sink = debugFrameSink, !exportedSizes.contains(canvas.label), shown > 0,
     let image = context.makeImage(), let png = UIImage(cgImage: image).pngData() {
   exportedSizes.insert(canvas.label)
   sink(canvas, png)
  }
  #endif
  return pixel
 }
}
