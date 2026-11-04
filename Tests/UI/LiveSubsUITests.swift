import XCTest

@MainActor
final class LiveSubsUITests: XCTestCase {
 private let placeholder = "uitest-invalid-placeholder-not-a-real-key"
 private var app: XCUIApplication!
 private func launchCleanApp() {
  continueAfterFailure = false
  app = XCUIApplication()
  app.launchArguments = ["--ui-testing"]
  app.launch()
 }
 private func capture(_ name: String) {
  let attachment = XCTAttachment(screenshot: app.screenshot())
  attachment.name = name
  attachment.lifetime = .keepAlways
  add(attachment)
 }
 private func reveal(_ element: XCUIElement) {
  for _ in 0..<6 {
   if element.exists && element.isHittable { return }
   app.swipeUp()
  }
 }
 func testLaunchPiPAndInvalidCredentialLifecycle() throws {
  launchCleanApp()
  defer { capture("final-state") }
  XCTAssertTrue(app.buttons["pip.start"].waitForExistence(timeout: 10))
  capture("launch")
  app.buttons["pip.start"].tap()
  let pip = app.staticTexts["pip.status"]
  let settled = NSPredicate { _, _ in
   guard pip.exists else { return false }
   return !["", "先开启画中画，再开始广播", "正在开启画中画"].contains(pip.label)
  }
  XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 15), .completed)
  XCTAssertEqual(app.state, .runningForeground, "PiP request must not terminate or background the app")
  let outcome: String
  if pip.label == "此设备不支持画中画" { outcome = "unsupported" }
  else if pip.label == "画中画已开启" { outcome = "actualdidstart" }
  else {
   XCTAssertTrue(["请在 App 前台、字幕预览可见时开启", "字幕预览尚未布局，请稍后再点", "音频会话启动失败", "字幕画面尚未就绪，请稍后再点", "无法创建画中画", "画中画尚未就绪，请稍后再点", "画中画启动失败，请导出诊断日志"].contains(pip.label), "Unclassified PiP outcome")
   outcome = "controlledfail"
  }
  let note = XCTAttachment(string: "PiP outcome=\(outcome); status=\(pip.label). Simulator does not validate device PiP/ReplayKit.")
  note.lifetime = .keepAlways
  add(note)
  capture("pip-\(outcome)")
  app.buttons["关闭"].tap()
  let key = app.secureTextFields["key.input"]
  reveal(key)
  XCTAssertTrue(key.isHittable)
  key.tap()
  key.typeText(placeholder)
  // Scroll the controls above the keyboard; do not depend on a localized return label.
  app.swipeUp()
  let save = app.buttons["key.save"]
  reveal(save)
  XCTAssertTrue(save.isHittable)
  save.tap()
  let status = app.staticTexts["connection.status"]
  XCTAssertTrue(status.waitForExistence(timeout: 5))
  XCTAssertTrue(status.label.hasPrefix("已保存"), status.label)
  app.terminate()
  app.launch()
  let length = app.staticTexts["key.persistedLength"]
  reveal(length)
  XCTAssertTrue(length.waitForExistence(timeout: 5))
  XCTAssertEqual(length.label, "Stored length: \(placeholder.count)", "Credential must survive process restart")
  reveal(app.buttons["key.save"])
  app.buttons["key.save"].tap()
  XCTAssertTrue(status.label.hasPrefix("已保存"))
  let test = app.buttons["key.test"]
  reveal(test)
  test.tap()
  let failed = NSPredicate { _, _ in
   guard status.exists else { return false }
   return ["连接失败", "Soniox 返回错误", "未收到有效识别响应"].contains { status.label.hasPrefix($0) }
  }
  XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: failed, object: nil)], timeout: 20), .completed, "Invalid placeholder must fail safely even without network")
  XCTAssertFalse(status.label.contains("连接可用"))
  XCTAssertEqual(app.state, .runningForeground)
  capture("invalid-key-controlled-error")
 }
}
