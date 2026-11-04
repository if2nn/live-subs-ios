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
 private func note(_ text: String) {
  let a = XCTAttachment(string: text); a.lifetime = .keepAlways; add(a)
 }
 private func openTab(_ name: String) {
  let tab = app.tabBars.buttons[name]
  if tab.waitForExistence(timeout: 5) { tab.tap(); return }
  let button = app.buttons[name].firstMatch
  XCTAssertTrue(button.waitForExistence(timeout: 5), "tab \(name)")
  button.tap()
 }
 private func reveal(_ element: XCUIElement, up: Bool = true) {
  for _ in 0..<8 {
   if element.exists && element.isHittable { return }
   up ? app.swipeUp() : app.swipeDown()
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

 func testSettingsKeyLanguagesDisplayAndStylePersist() throws {
  launch()
  defer { capture("settings-final") }
  openTab("设置")
  let key = app.secureTextFields["key.input"]
  XCTAssertTrue(key.waitForExistence(timeout: 10))
  key.tap(); key.typeText(placeholder)
  let save = app.buttons["key.save"]
  reveal(save)
  save.tap()
  let status = app.staticTexts["connection.status"]
  XCTAssertTrue(status.waitForExistence(timeout: 5))
  XCTAssertTrue(status.label.hasPrefix("已保存"), status.label)

  // Display mode.
  let display = app.segmentedControls["settings.display"]
  reveal(display)
  XCTAssertTrue(display.exists)
  display.buttons["仅译文"].tap()
  XCTAssertTrue(wait(app.staticTexts["settings.display.value"]) { $0.label.contains("仅译文") })
  // Style: order toggle and position.
  let order = app.switches["settings.order"]
  reveal(order)
  XCTAssertTrue(order.exists)
  if (order.value as? String) != "1" { order.tap() }
  if (order.value as? String) != "1" { order.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
  XCTAssertEqual(order.value as? String, "1", "order toggle switched on")
  let position = app.segmentedControls["settings.position"]
  reveal(position)
  position.buttons["顶部"].tap()
  capture("settings-changed")

  // Relaunch: key and settings survive.
  app.terminate()
  launch()
  openTab("设置")
  let length = app.staticTexts["key.persistedLength"]
  reveal(length)
  XCTAssertTrue(length.waitForExistence(timeout: 5))
  XCTAssertEqual(length.label, "Stored length: \(placeholder.count)", "credential survives restart")
  let value = app.staticTexts["settings.display.value"]
  reveal(value)
  XCTAssertTrue(value.label.contains("仅译文"), "display mode survives restart: \(value.label)")
  let order2 = app.switches["settings.order"]
  reveal(order2)
  XCTAssertEqual(order2.value as? String, "1", "order toggle survives restart")

  // Invalid key test fails safely (network or not).
  let test = app.buttons["key.test"]
  reveal(test, up: false)
  test.tap()
  let result = app.staticTexts["connection.status"]
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
  openTab("历史")
  let row = app.descendants(matching: .any).matching(identifier: "history.row").firstMatch
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
  XCTAssertTrue(app.descendants(matching: .any)["history.empty"].waitForExistence(timeout: 10), "entry deleted")
  // Deleted entries stay deleted after relaunch (without re-seeding).
  app.terminate()
  launch()
  openTab("历史")
  XCTAssertTrue(app.descendants(matching: .any)["history.empty"].waitForExistence(timeout: 10))
 }

 func testDiagnosticsPageShowsSigningAndCapture() throws {
  launch()
  defer { capture("diagnostics-final") }
  openTab("诊断")
  let text = app.staticTexts["diag.text"]
  XCTAssertTrue(text.waitForExistence(timeout: 10))
  XCTAssertTrue(text.label.contains("Bundle ID"), "signing diagnostics visible")
  XCTAssertTrue(text.label.contains("Main IPC relative path"), "capture diagnostics visible")
  XCTAssertFalse(text.label.contains(placeholder), "diagnostics never contain the key")
  XCTAssertTrue(app.buttons["diag.copy"].exists && app.buttons["diag.export"].exists)
 }
}
