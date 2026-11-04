import UIKit
import CoreMedia
import CoreVideo

/// Draws the caption frame into IOSurface-backed 32BGRA pixel buffers.
/// Preview 3 used non-IOSurface 32ARGB buffers, which a device video layer may
/// accept for enqueue yet never present (readyForDisplay stayed 0).
/// The PiP canvas is always opaque black (system PiP windows cannot be transparent).
@MainActor
final class CaptionRenderer {
 struct Content: Equatable {
  var original: String
  var translated: String
  var notice: String
  var settings: AppSettings
 }
 static let width = 1280
 private var pool: CVPixelBufferPool?
 private var poolHeight = 0

 /// Canvas height follows the chosen line count and font, so the PiP window
 /// keeps a caption-strip aspect instead of a mostly empty 16:9 frame.
 static func height(for settings: AppSettings) -> Int {
  let s = settings.style.normalized()
  let lanes = settings.display == .bilingual ? 2 : 1
  let main = s.fontSize * 2 * 1.25
  let secondary = s.fontSize * 2 * 0.78 * 1.25
  let textHeight = settings.display == .bilingual
   ? Double(s.lines) * (main + secondary) + 18
   : Double(s.lines) * (settings.display == .originalOnly ? secondary / 0.78 : main)
  let notice = 44.0
  let h = Int((textHeight + notice + 56 + Double(lanes - 1) * 8).rounded(.up))
  return min(max(h - h % 2, 240), 720)
 }

 private func buffer(height: Int) -> CVPixelBuffer? {
  if pool == nil || poolHeight != height {
   let attributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Self.width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
   ]
   var created: CVPixelBufferPool?
   CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                           attributes as CFDictionary, &created)
   pool = created; poolHeight = height
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
  let limit = lineHeight * CGFloat(lines) + 2
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

 func render(_ content: Content) -> CVPixelBuffer? {
  let settings = content.settings.normalized()
  let s = settings.style
  let height = Self.height(for: settings)
  guard let pixel = buffer(height: height) else { return nil }
  CVPixelBufferLockBaseAddress(pixel, [])
  defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
  guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: Self.width, height: height,
   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
   space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
  context.setFillColor(UIColor.black.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: Self.width, height: height))
  context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
  UIGraphicsPushContext(context)
  defer { UIGraphicsPopContext() }

  let width = CGFloat(Self.width) - 96
  let center = NSMutableParagraphStyle(); center.alignment = .center; center.lineBreakMode = .byWordWrapping
  let shadow = NSShadow(); shadow.shadowColor = UIColor.black; shadow.shadowBlurRadius = 6; shadow.shadowOffset = .zero
  let mainFont = UIFont.systemFont(ofSize: s.fontSize * 2, weight: .semibold)
  let secondFont = UIFont.systemFont(ofSize: s.fontSize * 2 * 0.78, weight: .medium)
  func attrs(_ font: UIFont, _ color: CaptionColor) -> [NSAttributedString.Key: Any] {
   [.font: font, .foregroundColor: Self.uiColor(color), .paragraphStyle: center, .shadow: shadow,
    .strokeColor: UIColor.black, .strokeWidth: -2.0]
  }
  struct Block { var text: String; var attributes: [NSAttributedString.Key: Any]; var lineHeight: CGFloat }
  var blocks: [Block] = []
  let original = Block(text: content.original, attributes: attrs(settings.display == .originalOnly ? mainFont : secondFont, s.originalColor),
                       lineHeight: (settings.display == .originalOnly ? mainFont : secondFont).lineHeight)
  let translated = Block(text: content.translated, attributes: attrs(mainFont, s.translationColor), lineHeight: mainFont.lineHeight)
  switch settings.display {
  case .originalOnly: blocks = [original]
  case .translationOnly: blocks = [translated]
  case .bilingual: blocks = s.translationFirst ? [translated, original] : [original, translated]
  }
  let fitted = blocks.map { b -> (String, Block) in
   (Self.fit(b.text, attributes: b.attributes, width: width, lines: s.lines, lineHeight: b.lineHeight), b)
  }
  let measured = fitted.map { pair -> CGFloat in
   pair.0.isEmpty ? 0 : min((pair.0 as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
    options: [.usesLineFragmentOrigin], attributes: pair.1.attributes, context: nil).height, pair.1.lineHeight * CGFloat(s.lines) + 2)
  }
  let gap: CGFloat = 8
  let total = measured.reduce(0, +) + gap * CGFloat(max(0, measured.filter { $0 > 0 }.count - 1))
  let noticeHeight: CGFloat = content.notice.isEmpty ? 0 : 44
  let available = CGFloat(height) - 28 - noticeHeight
  var y: CGFloat
  switch s.position {
  case .top: y = 20
  case .center: y = max(20, (available - total) / 2)
  case .bottom: y = max(20, available - total)
  }
  for (index, pair) in fitted.enumerated() where !pair.0.isEmpty {
   let h = measured[index]
   (pair.0 as NSString).draw(with: CGRect(x: 48, y: y, width: width, height: h + 2),
    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: pair.1.attributes, context: nil)
   y += h + gap
  }
  if !content.notice.isEmpty {
   let noticeAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26, weight: .medium),
    .foregroundColor: UIColor(white: 0.75, alpha: 1), .paragraphStyle: center]
   (content.notice as NSString).draw(with: CGRect(x: 48, y: CGFloat(height) - noticeHeight - 6, width: width, height: noticeHeight),
    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: noticeAttrs, context: nil)
  }
  return pixel
 }
}
