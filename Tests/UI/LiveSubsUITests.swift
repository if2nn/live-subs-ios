import XCTest

/// Simulator UI gate. It checks the app's own UI and controlled failures only;
/// it never claims ReplayKit capture, SideStore signing or device PiP.
@MainActor
final class LiveSubsUITests: XCTestCase {
 private let placeholder = "uitest-invalid-placeholder-not-a-real-key"
 private var app: XCUIApplication!

 override func setUp() async throws {
  continueAfterFailure = false
 }
 private func launch(_ extra: [String] = []) {
  app = XCUIApplication()
  app.launchArguments = ["--ui-testing"] + extra
  app.launch()
 }
 private func capture(_ name: String) {
  let attachment = XCTAttachment(screenshot: app.screenshot())
  attachment.name = name; attachment.lifetime = .keepAlways
  add(attachment)
 }
 /// A switch's value is "1"/"0" as a String on some runtimes and an NSNumber on others.
 private static func isOn(_ element: XCUIElement) -> Bool {
  switch element.value {
  case let s as String: return s == "1"
  case let n as NSNumber: return n.intValue == 1
  default: return false
  }
 }
 private func note(_ text: String) {
  let a = XCTAttachment(string: text); a.lifetime = .keepAlways; add(a)
 }
 private func openTab(_ name: String) {
  // iOS 27 simulators do not expose the SwiftUI tab bar as `tabBars`; waiting
  // on that query first cost 5 s and several full accessibility snapshots per
  // call (each failed wait captures a debug description), which pushed slow
  // runners into "Timed out while evaluating UI query". Query the button directly.
  let button = app.buttons[name].firstMatch
  XCTAssertTrue(button.waitForExistence(timeout: 15), "tab \(name)")
  button.tap()
 }
 /// Opens a settings row that pushes a second-level page (preview 6 layout).
 private func push(_ identifier: String) {
  let link = app.buttons[identifier].firstMatch
  reveal(link)
  XCTAssertTrue(link.waitForExistence(timeout: 10), "link \(identifier)")
  link.tap()
 }
 private func back() {
  // iOS 27 sims expose the system back button as identifier "BackButton"
  // (not reliably under navigationBars).
  let button = app.buttons["BackButton"].firstMatch
  XCTAssertTrue(button.waitForExistence(timeout: 5), "back button")
  button.tap()
 }
 private func reveal(_ element: XCUIElement, up: Bool = true) {
  // Gentle swipes on the scroll container (not on whatever control sits at the
  // screen centre, e.g. a Slider) so lazily-built rows are never skipped.
  let scroller = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
  for _ in 0..<14 {
   if element.exists && element.isHittable { return }
   // Drag along the left margin: a centre swipe lands on a Slider and moves it
   // instead of scrolling (seen on the iOS 27 simulator).
   let target: XCUIElement = scroller.exists ? scroller : (app! as XCUIElement)
   let low = target.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.78))
   let high = target.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.32))
   up ? low.press(forDuration: 0.05, thenDragTo: high) : high.press(forDuration: 0.05, thenDragTo: low)
  }
 }
 private func wait(_ element: XCUIElement, timeout: TimeInterval = 10, _ predicate: @escaping (XCUIElement) -> Bool) -> Bool {
  let p = NSPredicate { _, _ in element.exists && predicate(element) }
  return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: nil)], timeout: timeout) == .completed
 }

 private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
  let p = NSPredicate { _, _ in !element.exists }
  return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: nil)], timeout: timeout) == .completed
 }

 func testLiveTabPiPRequestIsControlled() throws {
  launch()
  defer { capture("live-final") }
  XCTAssertTrue(app.buttons["start.oneTap"].waitForExistence(timeout: 10))
  // Without a saved key, one-tap start is disabled with a visible reason.
  if app.staticTexts["start.needsKey"].exists { XCTAssertFalse(app.buttons["start.oneTap"].isEnabled) }
  let captureStatus = app.staticTexts["capture.status"]
  XCTAssertTrue(captureStatus.waitForExistence(timeout: 10))
  XCTAssertFalse(captureStatus.label.contains("正在识别"), "no broadcast has been started")
  capture("live-launch")

  let pipStart = app.buttons["pip.start"]
  reveal(pipStart)
  pipStart.tap()
  let status = app.staticTexts["pip.status"]
  let allowed = ["此设备不支持画中画", "悬浮字幕已开启", "系统暂不允许", "系统正在准备", "正在开启悬浮字幕", "系统未响应", "悬浮字幕启动失败", "音频会话启动失败", "请在字幕页前台开启"]
  XCTAssertTrue(wait(status, timeout: 12) { el in allowed.contains { el.label.contains($0) } }, "PiP outcome must be classified: \(status.label)")
  // Give a started PiP (if the simulator supports it) time to settle, then stop.
  sleep(2)
  XCTAssertEqual(app.state, .runningForeground, "PiP request must not terminate the app")
  note("Simulator PiP outcome: \(status.label). Not device PiP evidence.")
  capture("live-pip-outcome")
  let stop = app.buttons["pip.stop"]
  reveal(stop)
  if stop.isHittable { stop.tap() }
  XCTAssertEqual(app.state, .runningForeground)
 }

 /// Preview 5: captions are rasterised at the screen scale in both shapes;
 /// the classic (preview 4) shape is the default and the strip is optional.
 /// Simulator evidence only; real-device PiP sharpness is Ian's call.
 func testCaptionWindowShapesRenderAtScreenScale() throws {
  launch(["--ui-testing-seed-caption"])
  openTab("字幕")
  let size = app.staticTexts["pip.frame.size"]
  XCTAssertTrue(wait(size, timeout: 10) { !$0.label.isEmpty }, "a frame was rendered")
  // Screen scale = screenshot pixels / window points (independent of UIImage.scale).
  let shot = XCUIScreen.main.screenshot().image
  let px = min(shot.size.width, shot.size.height) * shot.scale
  let window = app.windows.firstMatch.frame
  let scale = Int((px / max(min(window.width, window.height), 1)).rounded())
  func dims(_ label: String) -> (Int, Int)? {
   let d = label.split(separator: " ").first?.split(separator: "x").compactMap { Int($0) } ?? []
   return d.count == 2 ? (d[0], d[1]) : nil
  }
  let classicLabel = size.label
  note("Classic caption frame: \(classicLabel); simulator screen scale \(scale)x")
  capture("caption-classic")
  guard let classic = dims(classicLabel) else { return XCTFail(classicLabel) }
  XCTAssertEqual(classic.0, 480 * scale, "classic width = 480 pt x screen scale: \(classicLabel)")
  XCTAssertTrue(classicLabel.hasSuffix("@\(scale)x"), classicLabel)
  XCTAssertFalse(classicLabel.hasPrefix("1280x"), "not the fixed 1280 px preview 4 frame")

  openTab("设置")
  let shape = app.segmentedControls["settings.pipShape"]
  reveal(shape)
  XCTAssertTrue(shape.exists, "shape switch in Settings")
  XCTAssertTrue(shape.buttons["经典"].isSelected, "classic is the default")
  shape.buttons["长条"].tap()
  XCTAssertTrue(wait(shape.buttons["长条"]) { $0.isSelected })
  capture("settings-shape-strip")

  openTab("字幕")
  XCTAssertTrue(wait(size, timeout: 10) { $0.label != classicLabel }, "frame re-rendered for the strip")
  let stripLabel = size.label
  note("Strip caption frame: \(stripLabel)")
  capture("caption-strip")
  guard let strip = dims(stripLabel) else { return XCTFail(stripLabel) }
  XCTAssertEqual(strip.0, 480 * scale, "strip width = 480 pt x screen scale: \(stripLabel)")
  XCTAssertEqual(strip.1, 112 * scale, "strip height = 112 pt x screen scale: \(stripLabel)")
  XCTAssertGreaterThan(Double(strip.0) / Double(strip.1), Double(classic.0) / Double(classic.1), "strip is wider and flatter than classic")

  // Switching back restores the classic shape (the option does not replace it).
  openTab("设置")
  reveal(shape)
  shape.buttons["经典"].tap()
  openTab("字幕")
  XCTAssertTrue(wait(size, timeout: 10) { $0.label == classicLabel }, "classic restored: \(size.label)")
  XCTAssertEqual(app.state, .runningForeground)
 }

 func testSettingsKeyLanguagesDisplayAndStylePersist() throws {
  launch()
  defer { capture("settings-final") }
  openTab("设置")
  push("settings.apiKey")
  let key = app.secureTextFields["key.input"]
  XCTAssertTrue(key.waitForExistence(timeout: 10))
  key.tap(); key.typeText(placeholder)
  let save = app.buttons["key.save"]
  reveal(save)
  save.tap()
  let status = app.staticTexts["connection.status"]
  XCTAssertTrue(status.waitForExistence(timeout: 5))
  XCTAssertTrue(status.label.hasPrefix("已保存"), status.label)
  back()

  // Display mode.
  let display = app.segmentedControls["settings.display"]
  reveal(display)
  XCTAssertTrue(display.exists)
  display.buttons["仅译文"].tap()
  XCTAssertTrue(wait(display.buttons["仅译文"], timeout: 5) { $0.isSelected }, "segment selected")
  // The caption row under the picker is a separate lazy cell; bring it on screen.
  let displayValue = app.staticTexts["settings.display.value"]
  reveal(displayValue)
  XCTAssertTrue(wait(displayValue) { $0.label.contains("仅译文") }, "display value: \(displayValue.label)")
  // Style (设置 → 字幕样式): order toggle and position.
  push("settings.styleLink")
  let orderQuery = NSPredicate(format: "identifier == 'settings.order' OR label == '译文在上'")
  let order = app.switches.matching(orderQuery).firstMatch
  reveal(order)
  XCTAssertTrue(order.exists)
  // Tap once and let the value settle before deciding on a second attempt,
  // otherwise a slow update reads as "0" and the retry flips it back.
  if !Self.isOn(order) {
   // SwiftUI exposes the row as a Switch whose centre is the label; the real
   // UISwitch is a nested Switch. Tap that one (known iOS 18+ behaviour).
   let knob = order.switches.firstMatch
   (knob.exists ? knob : order).tap()
   if !wait(order, timeout: 4, { Self.isOn($0) }) {
    let frame = order.frame
    order.coordinate(withNormalizedOffset: .zero)
     .withOffset(CGVector(dx: frame.width - 30, dy: frame.height / 2)).tap()
   }
  }
  XCTAssertTrue(wait(order, timeout: 4) { Self.isOn($0) }, "order toggle switched on: \(String(describing: order.value))")
  let position = app.segmentedControls["settings.position"]
  reveal(position)
  position.buttons["顶部"].tap()
  capture("settings-changed")

  // Relaunch: key and settings survive.
  app.terminate()
  launch()
  openTab("设置")
  push("settings.apiKey")
  let length = app.staticTexts["key.persistedLength"]
  reveal(length)
  XCTAssertTrue(length.waitForExistence(timeout: 5))
  XCTAssertEqual(length.label, "Stored length: \(placeholder.count)", "credential survives restart")
  back()
  let value = app.staticTexts["settings.display.value"]
  reveal(value)
  XCTAssertTrue(value.label.contains("仅译文"), "display mode survives restart: \(value.label)")
  push("settings.styleLink")
  let order2 = app.switches.matching(orderQuery).firstMatch
  reveal(order2)
  XCTAssertTrue(Self.isOn(order2), "order toggle survives restart: \(String(describing: order2.value))")
  back()
  push("settings.apiKey")

  // Invalid key test fails safely (network or not).
  let test = app.buttons["key.test"]
  reveal(test, up: false)
  test.tap()
  let result = app.staticTexts["connection.status"]
  // The status row can sit outside the lazily-built part of the list after the
  // tap; bring it on screen before reading it.
  if !result.waitForExistence(timeout: 5) { reveal(result, up: true) }
  if !result.exists { reveal(result, up: false) }
  if !result.exists { capture("settings-status-missing") }
  XCTAssertTrue(wait(result, timeout: 25) { el in ["连接失败", "Soniox 返回错误", "未收到有效识别响应"].contains { el.label.hasPrefix($0) } },
   "invalid key must fail safely: \(result.label)")
  XCTAssertFalse(result.label.contains("连接可用"))

  // With a key saved, the one-tap start is enabled.
  openTab("字幕")
  XCTAssertTrue(wait(app.buttons["start.oneTap"]) { $0.isEnabled })
 }

 func testHistoryViewCopyDelete() throws {
  launch(["--ui-testing-seed-history"])
  defer { capture("history-final") }
  openTab("字幕")
  let records = app.buttons["records.open"].firstMatch
  XCTAssertTrue(records.waitForExistence(timeout: 10), "记录 on the captions page")
  records.tap()
  // A NavigationLink row is a button; avoid descendants(.any), which snapshots
  // the whole tree and times out on the iOS 27 simulator.
  let row = app.buttons.matching(NSPredicate(format: "identifier == 'history.row' OR label CONTAINS '→'")).firstMatch
  XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded history row")
  row.tap()
  XCTAssertTrue(app.staticTexts["大家好，欢迎回来。"].waitForExistence(timeout: 5))
  XCTAssertTrue(app.staticTexts["Hello everyone, welcome back."].exists)
  // Translation-only hides originals.
  app.segmentedControls["history.mode"].buttons["仅译文"].tap()
  XCTAssertTrue(waitGone(app.staticTexts["Hello everyone, welcome back."]), "translation-only hides originals")
  XCTAssertTrue(app.staticTexts["大家好，欢迎回来。"].exists)
  app.buttons["history.copy"].tap()
  XCTAssertTrue(app.staticTexts["history.copied"].waitForExistence(timeout: 5))
  XCTAssertTrue(app.buttons["history.share"].exists)
  capture("history-detail")
  app.buttons["history.delete"].tap()
  let confirm = app.buttons["删除"].firstMatch
  XCTAssertTrue(confirm.waitForExistence(timeout: 5))
  confirm.tap()
  XCTAssertTrue(app.staticTexts["还没有字幕记录"].waitForExistence(timeout: 10), "entry deleted")
  // Deleted entries stay deleted after relaunch (without re-seeding).
  app.terminate()
  launch()
  openTab("设置")
  push("settings.records")
  XCTAssertTrue(app.staticTexts["还没有字幕记录"].waitForExistence(timeout: 10), "deleted entry not re-imported")
 }

 func testTabsAndSettingsSubpages() throws {
  launch()
  defer { capture("tabs-final") }
  for name in ["字幕", "同传", "转录", "设置"] {
   XCTAssertTrue(app.buttons[name].firstMatch.waitForExistence(timeout: 15), "tab \(name)")
  }
  XCTAssertFalse(app.buttons["历史"].exists, "history tab removed")
  XCTAssertFalse(app.buttons["诊断"].exists, "diagnostics tab removed")
  openTab("同传")
  XCTAssertTrue(app.buttons["records.open"].firstMatch.waitForExistence(timeout: 10), "记录 on interpret page")
  capture("tab-interpret")
  openTab("转录")
  XCTAssertTrue(app.buttons["records.open"].firstMatch.waitForExistence(timeout: 10), "记录 on transcribe page")
  capture("tab-transcribe")
  openTab("设置")
  for id in ["settings.apiKey", "settings.styleLink", "settings.records", "settings.diagnostics"] {
   let link = app.buttons[id].firstMatch
   reveal(link)
   XCTAssertTrue(link.exists, "settings row \(id)")
  }
  let version = app.descendants(matching: .any)["settings.version"].firstMatch
  reveal(version)
  capture("settings-root")
  XCTAssertEqual(app.state, .runningForeground)
 }

 func testAppearanceFollowsSettingNotForcedDark() throws {
  launch()
  defer { capture("appearance-final") }
  openTab("设置")
  let appearance = app.segmentedControls["settings.appearance"]
  reveal(appearance)
  XCTAssertTrue(appearance.waitForExistence(timeout: 10), "appearance control present")
  XCTAssertTrue(appearance.buttons["跟随系统"].isSelected, "appearance defaults to follow system")
  appearance.buttons["浅色"].tap()
  XCTAssertTrue(wait(appearance.buttons["浅色"]) { $0.isSelected }, "appearance switched to light")
  capture("appearance-light")
  app.terminate()
  launch()
  openTab("设置")
  let appearance2 = app.segmentedControls["settings.appearance"]
  reveal(appearance2)
  XCTAssertTrue(appearance2.buttons["浅色"].isSelected, "appearance survives restart")
  XCTAssertEqual(app.state, .runningForeground)
 }

 func testDiagnosticsPageShowsSigningAndCapture() throws {
  launch()
  defer { capture("diagnostics-final") }
  openTab("设置")
  push("settings.diagnostics")
  let text = app.staticTexts["diag.text"]
  XCTAssertTrue(text.waitForExistence(timeout: 10))
  XCTAssertTrue(text.label.contains("Bundle ID"), "signing diagnostics visible")
  XCTAssertTrue(text.label.contains("Main IPC relative path"), "capture diagnostics visible")
  XCTAssertFalse(text.label.contains(placeholder), "diagnostics never contain the key")
  XCTAssertTrue(app.buttons["diag.copy"].exists && app.buttons["diag.export"].exists)
 }
}
