import Foundation

/// Geometry of the PiP caption window, free of UIKit so it is unit-tested on CI.
///
/// Layout is done in points on a 480 pt-wide canvas. Pixels = points × scale,
/// so glyphs are rasterised at the density they are shown at, instead of a fixed
/// 1280 px frame (preview 4) that the compositor resampled.
///
/// Two shapes (Settings → 悬浮窗形状):
/// - `classic` (default, the preview 4 shape): height follows font size, line
///   count and display mode, as before;
/// - `strip` (optional): a fixed 480 × 112 pt (≈4.3:1) subtitle bar, wide and
///   flat, a little taller than a one-line strip: about two lines of bilingual
///   text (translation + original) at the default size.
struct CaptionCanvas: Equatable, Sendable {
 static let pointWidth = 480.0
 static let stripPointHeight = 112.0   // 480×112 pt ≈ 4.3:1, one translation + one original line
 static let classicPointRange = 90.0...270.0   // preview 4 clamp 240…720 px at 1280 px wide
 static let minPixelWidth = 480
 static let maxPixelWidth = 2400

 let pixelWidth: Int
 let pixelHeight: Int
 let pointHeight: Double
 var scale: Double { Double(pixelWidth) / Self.pointWidth }
 var aspect: Double { Self.pointWidth / pointHeight }

 /// Point height of the PiP window for these settings.
 static func pointHeight(for settings: AppSettings) -> Double {
  let s = settings.normalized()
  switch s.pipShape {
  case .strip:
   return stripPointHeight
  case .classic:
   // Room for the chosen lines at the chosen size, plus a footnote band.
   let t = CaptionTypography.natural(s)
   let h = t.textHeight(display: s.display) + 2 * CaptionTypography.verticalPadding + CaptionTypography.footnoteBand
   return min(max(h.rounded(.up), classicPointRange.lowerBound), classicPointRange.upperBound)
  }
 }

 static func aspect(for settings: AppSettings) -> Double { pointWidth / pointHeight(for: settings) }

 /// Before PiP reports its window, render at the screen's native scale
 /// (480 pt × 3 = 1440 px wide on a 3x iPhone). Once AVKit reports the PiP
 /// render size, match the pixels the aspect-fit frame occupies in that
 /// window, so the compositor shows it 1:1 with no resampling.
 static func make(screenScale: Double, pointHeight: Double, renderSize: (width: Int, height: Int)? = nil) -> CaptionCanvas {
  let s = screenScale.isFinite && screenScale >= 1 ? min(screenScale, 4) : 3
  let ph = pointHeight.isFinite && pointHeight > 0 ? pointHeight : stripPointHeight
  let aspect = pointWidth / ph
  var w = Int((pointWidth * s).rounded())
  if let r = renderSize, r.width > 0, r.height > 0 {
   w = min(r.width, Int((Double(r.height) * aspect).rounded(.down)))
  }
  w = min(max(w, minPixelWidth), maxPixelWidth)
  w -= w % 2
  var h = Int((Double(w) / aspect).rounded())
  h -= h % 2
  return CaptionCanvas(pixelWidth: w, pixelHeight: max(h, 2), pointHeight: ph)
 }

 static func make(screenScale: Double, settings: AppSettings, renderSize: (width: Int, height: Int)? = nil) -> CaptionCanvas {
  make(screenScale: screenScale, pointHeight: pointHeight(for: settings), renderSize: renderSize)
 }

 var label: String {
  let s = scale
  let scaleText = s == s.rounded() ? String(Int(s)) : String(format: "%.2f", s)
  return "\(pixelWidth)x\(pixelHeight) @\(scaleText)x"
 }
}

/// Font sizes (in points) and the number of lines per lane that fit the window.
struct CaptionTypography: Equatable, Sendable {
 static let lineFactor = 1.3      // fixed line height = pt × factor (CJK fallback included)
 static let verticalPadding = 10.0
 static let horizontalPadding = 18.0
 static let laneGap = 6.0
 static let footnotePoints = 12.0
 static var footnoteBand: Double { lineHeight(footnotePoints) + 2 }

 var mainPoints: Double         // translation (or the only lane)
 var secondaryPoints: Double    // original text
 var lines: Int                 // lines per lane that fit
 var noticePoints: Double
 var noticeHeight: Double       // footnote band at the bottom (0 when none)

 /// Sizes and line count as the user chose them, before fitting a window.
 static func natural(_ settings: AppSettings) -> CaptionTypography {
  let s = settings.normalized()
  // The style's font size (18…48, default 30) maps to 13.5…36 pt; default 22.5 pt
  // (preview 4 drew fontSize × 2 px on a 1280 px canvas: the same proportion).
  let main = s.style.fontSize * 0.75
  let secondary = s.display == .originalOnly ? main : main * 0.78
  return CaptionTypography(mainPoints: main, secondaryPoints: secondary, lines: s.style.lines,
                           noticePoints: footnotePoints, noticeHeight: 0)
 }

 /// `hasNotice` is a status footnote under live captions; an empty window
 /// shows its message centred instead and reserves no footnote band.
 static func make(_ settings: AppSettings, hasNotice: Bool, hasCaption: Bool) -> CaptionTypography {
  let s = settings.normalized()
  var t = natural(s)
  var main = t.mainPoints, secondary = t.secondaryPoints
  let footnote = hasNotice && hasCaption
  t.noticeHeight = footnote ? footnoteBand : 0
  let available = CaptionCanvas.pointHeight(for: s) - 2 * verticalPadding - t.noticeHeight
  var lines: Int
  if s.display == .bilingual {
   let perLine = lineHeight(main) + lineHeight(secondary)
   lines = Int(((available - laneGap) / perLine).rounded(.down))
   if lines < 1 {
    let f = (available - laneGap) / (lineFactor * (main + secondary)) * 0.97
    main *= f; secondary *= f; lines = 1
   }
  } else {
   let size = s.display == .originalOnly ? secondary : main
   lines = Int((available / lineHeight(size)).rounded(.down))
   if lines < 1 {
    let f = available / (lineFactor * size) * 0.97
    main *= f; secondary *= f; lines = 1
   }
  }
  t.mainPoints = main; t.secondaryPoints = secondary
  t.lines = min(lines, s.style.lines)
  t.noticePoints = hasCaption ? footnotePoints : max(14, main * 0.72)
  return t
 }

 static func lineHeight(_ points: Double) -> Double { (points * lineFactor).rounded(.up) }

 /// Total text height for the lanes shown, in points.
 func textHeight(display: DisplayMode) -> Double {
  switch display {
  case .bilingual: return Double(lines) * (Self.lineHeight(mainPoints) + Self.lineHeight(secondaryPoints)) + Self.laneGap
  case .translationOnly: return Double(lines) * Self.lineHeight(mainPoints)
  case .originalOnly: return Double(lines) * Self.lineHeight(secondaryPoints)
  }
 }
}
