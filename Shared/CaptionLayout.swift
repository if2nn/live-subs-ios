import Foundation

/// Geometry of the PiP caption strip, free of UIKit so it is unit-tested on CI.
///
/// Layout is done in points on a fixed 480 × 160 pt strip (3:1): wide and flat
/// like a subtitle bar, with room for about two bilingual lines. Pixels are
/// points × scale, so glyphs are rasterised at the density they are shown at
/// instead of being drawn small and scaled up by the compositor.
struct CaptionCanvas: Equatable, Sendable {
 static let pointWidth = 480.0
 static let pointHeight = 160.0
 static let aspect = pointWidth / pointHeight
 static let minPixelWidth = 480
 static let maxPixelWidth = 2400

 let pixelWidth: Int
 let pixelHeight: Int
 var scale: Double { Double(pixelWidth) / Self.pointWidth }

 /// Before PiP reports its window, render at the screen's native scale
 /// (480 pt × 3 = 1440 px on a 3x iPhone). Once AVKit reports the PiP render
 /// size, match the pixels the 3:1 frame actually occupies in that window
 /// (aspect-fit), so the compositor shows it 1:1 with no resampling.
 static func make(screenScale: Double, renderSize: (width: Int, height: Int)? = nil) -> CaptionCanvas {
  let s = screenScale.isFinite && screenScale >= 1 ? min(screenScale, 4) : 3
  var w = Int((pointWidth * s).rounded())
  if let r = renderSize, r.width > 0, r.height > 0 {
   w = min(r.width, Int((Double(r.height) * aspect).rounded()))
  }
  w = min(max(w, minPixelWidth), maxPixelWidth)
  w -= w % 6 // width divisible by 6 keeps the 3:1 height an even integer
  return CaptionCanvas(pixelWidth: w, pixelHeight: w / 3)
 }

 var label: String {
  let s = scale
  let scaleText = s == s.rounded() ? String(Int(s)) : String(format: "%.2f", s)
  return "\(pixelWidth)x\(pixelHeight) @\(scaleText)x"
 }
}

/// Font sizes (in points) and the number of lines per lane that fit the strip.
struct CaptionTypography: Equatable, Sendable {
 static let lineFactor = 1.3      // fixed line height = pt × factor (CJK fallback included)
 static let verticalPadding = 10.0
 static let horizontalPadding = 18.0
 static let laneGap = 6.0
 static let footnotePoints = 12.0

 var mainPoints: Double         // translation (or the only lane)
 var secondaryPoints: Double    // original text in bilingual mode
 var lines: Int                 // lines per lane that fit
 var noticePoints: Double
 var noticeHeight: Double       // footnote band at the bottom (0 when none)

 /// `hasNotice` is a status footnote under live captions; an empty window
 /// shows its message centred instead and reserves no footnote band.
 static func make(_ settings: AppSettings, hasNotice: Bool, hasCaption: Bool) -> CaptionTypography {
  let s = settings.normalized()
  // The style's font size (18…48, default 30) maps to 13.5…36 pt; default 22.5 pt.
  var main = s.style.fontSize * 0.75
  var secondary = settings.display == .originalOnly ? main : main * 0.78
  let footnote = hasNotice && hasCaption
  let noticeHeight = footnote ? (footnotePoints * lineFactor).rounded(.up) + 2 : 0
  let available = CaptionCanvas.pointHeight - 2 * verticalPadding - noticeHeight
  var lines: Int
  if settings.display == .bilingual {
   let perLine = lineFactor * (main + secondary)
   lines = Int(((available - laneGap) / perLine).rounded(.down))
   if lines < 1 {
    let f = (available - laneGap) / perLine
    main *= f; secondary *= f; lines = 1
   }
  } else {
   let size = settings.display == .originalOnly ? secondary : main
   lines = Int((available / (lineFactor * size)).rounded(.down))
   if lines < 1 {
    let f = available / (lineFactor * size)
    main *= f; secondary *= f; lines = 1
   }
  }
  lines = min(lines, s.style.lines)
  let notice = hasCaption ? footnotePoints : max(14, main * 0.72)
  return CaptionTypography(mainPoints: main, secondaryPoints: secondary, lines: lines,
                           noticePoints: notice, noticeHeight: noticeHeight)
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
