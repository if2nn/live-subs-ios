import Foundation

enum CaptureEvent: String, Codable, Sendable {
 case entered, discovered, started, paused, resumed, stopped, keyRead
 case connecting, transportOpen, configSent, protocolConfirmed
 case transportError, protocolError, retrying, conversionError, fatal, serverFinished
}
struct CaptureSnapshot: Codable, Sendable {
 var schema = 1
 var session = UUID().uuidString
 var bundleID = ""
 var group: String?
 var container = false
 var relativePath = "Capture/state.json"
 var heartbeat = Date()
 var began = Date()
 var lifecycle = "starting"
 var transport = "idle"
 var authentication = "pending"
 var keySuccess: Bool?
 var keyOSStatus: Int32?
 var audioAppBuffers: UInt64 = 0
 var audioAppFrames: UInt64 = 0
 var lastAudio: Date?
 var sourceTokens: UInt64 = 0
 var translationTokens: UInt64 = 0
 var lastSource: Date?
 var lastTranslation: Date?
 var residentBytes: UInt64 = 0
 var peakResidentBytes: UInt64 = 0
 var memorySamples: UInt64 = 0
 var errorDomain: String?
 var errorCode: Int?
}
struct CaptureLogEntry: Codable, Sendable {
 let time: Date
 let event: CaptureEvent
 let code: Int?
 let domain: String?
}
enum CaptureState {
 static func status(_ s: CaptureSnapshot?, now: Date = Date(), sharedAvailable: Bool = true) -> String {
  guard sharedAvailable else { return "未收到扩展心跳，无法区分未启动、崩溃或无共享权限（主 App 共享容器不可用）" }
  guard let s = s else { return "等待系统录屏；未收到扩展心跳，无法区分未启动、崩溃或无共享权限" }
  if s.lifecycle == "stopped" { return "广播已停止，请重新开启系统录屏" }
  if now.timeIntervalSince(s.heartbeat) > 10 { return "扩展心跳已过期，可能中断或无法共享，尚未确认停止" }
  if s.keySuccess == false { return "扩展 Key 读取失败，请检查共享钥匙串签名" }
  if s.lifecycle == "paused" { return "广播已暂停" }
  if s.authentication == "failure" { return "Soniox 认证失败" }
  if s.transport == "closed" { return "Soniox 会话已结束；扩展尚未报告停止" }
  if s.transport == "error" { return "网络连接错误，等待重连" }
  if s.lifecycle == "failed" { return "扩展报告错误，请查看诊断" }
  if s.transport == "connecting" || s.transport == "idle" { return "扩展已启动，连接中" }
  if let last = s.lastAudio, now.timeIntervalSince(last) > 8 { return "近期未收到 App 音频" }
  if s.audioAppFrames == 0 { return "已连接，等待 App 音频；认证状态 " + (s.authentication == "confirmed" ? "已确认" : "待确认") }
  if s.authentication != "confirmed" { return "已收到音频，等待 Soniox 有效响应确认认证" }
  if s.sourceTokens == 0 && s.translationTokens == 0 { return "有音频，等待识别" }
  return "正在识别与翻译"
 }
 // Operates on raw Store caption strings. Never persists or logs presentation text.
 static func presentation(snapshot: CaptureSnapshot?, original: String, translated: String,
                          updated: Date, now: Date = Date(), sharedAvailable: Bool = true)
   -> (original:String, translated:String, status:String) {
  let text=status(snapshot,now:now,sharedAvailable:sharedAvailable)
  let hasText = !original.isEmpty || !translated.isEmpty
  let uncertain = !sharedAvailable || snapshot == nil ||
   snapshot.map { now.timeIntervalSince($0.heartbeat) > 10 ||
    $0.lifecycle != "started" || $0.keySuccess == false ||
    $0.authentication != "confirmed" || $0.transport != "configured" ||
    $0.lastAudio.map { now.timeIntervalSince($0) > 8 } == true } == true
  let old = hasText && now.timeIntervalSince(updated) > 12
  guard uncertain || old || !hasText else { return (original,translated,text) }
  let notice=text + (hasText ? "（保留上次字幕）" : "")
  // First lane is rendered even when translated is nonempty. Prefix only once,
  // including defensive handling if a caller accidentally reuses presentation.
  let rawOriginal: String
  if original.hasPrefix("〔状态〕"), let end=original.range(of:"〔/状态〕") {
   rawOriginal=String(original[end.upperBound...]).trimmingCharacters(in:.newlines)
  } else { rawOriginal=original }
  let displayNotice: String
  if !sharedAvailable || snapshot == nil {
   displayNotice="未收到扩展心跳，无法区分未启动、崩溃或无共享权限" + (hasText ? "（旧字幕）" : "")
  } else { displayNotice=text + (hasText ? "（旧字幕）" : "") }
  let line="〔状态〕" + displayNotice + "〔/状态〕"
  return (line + (rawOriginal.isEmpty ? "" : " " + String(rawOriginal.prefix(12))),
          translated,notice)
 }
}
