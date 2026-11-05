import Foundation

/// All page-level UI copy in one place (preview 6, plan §3.6) so it can be
/// reviewed at once. Rules: buttons are 2-4 character verb phrases, states are
/// noun phrases, no full sentences, no 你/我们/将会, explanations live in the
/// manual (Manual.swift). static_checks enforces the length rule on App views.
///
/// PiP / capture status lines (CaptionPiP.swift) and key-test results
/// (Stores.swift) are runtime status, not page copy; they are unchanged in S2
/// because the UI gate classifies them by prefix.
enum S {
 // Tabs
 static let tabCaptions = "字幕"
 static let tabInterpret = "同传"
 static let tabTranscribe = "转录"
 static let tabSettings = "设置"

 // Page titles
 static let titleCaptions = "字幕"
 static let titleInterpret = "同声传译"
 static let titleTranscribe = "音频转录"
 static let titleSettings = "设置"
 static let titleRecords = "记录"
 static let titleAPIKey = "API Key"
 static let titleStyle = "字幕样式"
 static let titleDiagnostics = "诊断"
 static let titleManual = "使用手册"

 // Common
 static let records = "记录"
 static let comingSoon = "即将推出"
 static let manualLink = "使用手册"
 static let copy = "复制"
 static let copied = "已复制"
 static let share = "分享"
 static let delete = "删除"

 // Captions page
 static let start = "开始"
 static let pipOnly = "仅悬浮窗"
 static let stop = "停止"
 static let restart = "重新开始"
 static let captureStopped = "录屏已停止"
 static let captureStale = "录屏信号中断"
 static let noKey = "未设置 API Key"
 static let goToSettings = "去设置"

 // 同声传译
 static let interpretMode = "模式"
 static let me = "我"
 static let opposite = "对面"
 static let flipOpposite = "翻转对面"
 static let interpretBusy = "字幕运行中"
 static let captionsBusy = "同传运行中"
 static let interpretStarting = "正在开始…"
 static let interpretRunning = "正在同传"
 static let interpretStopping = "正在保存…"
 static let interpretSaved = "已存入记录"
 static let interpretFailed = "同传已中断"
 static let micDenied = "未允许麦克风"
 static let micFailed = "麦克风启动失败"
 static let keyInvalid = "API Key 无效"
 static let noBalance = "余额不足"

 // Records
 static let recordsEmpty = "暂无记录"
 static let inProgress = " · 进行中"
 static let display = "显示"
 static let pending = "未完成："
 static let deleteRecord = "删除记录"
 static let deleteRecordConfirm = "删除这条记录？"

 // Settings
 static let sectionAccount = "账户"
 static let sectionAppearance = "外观"
 static let sectionCaptions = "字幕"
 static let sectionData = "数据"
 static let sectionHelp = "帮助"
 static let sectionAbout = "关于"
 static let keySaved = "已保存"
 static let keyMissing = "未设置"
 static let appearance = "外观"
 static let appearanceFooter = "悬浮窗始终为黑底"
 static let sourceLanguage = "源语言"
 static let targetLanguage = "目标语言"
 static let mode = "模式"
 static let current = "当前："
 static let pipShape = "悬浮窗形状"
 static let languageFooter = "下次开始时生效"
 static let version = "版本"

 // API Key page
 static let keyPlaceholderSaved = "已保存"
 static let keyPlaceholder = "Soniox API Key"
 static let saveKey = "保存"
 static let testing = "测试中…"
 static let testConnection = "测试连接"
 static let keyHeader = "Soniox Key"

 // Style page
 static func fontSize(_ v: Int) -> String { "字号 \(v)" }
 static func linesPerLane(_ v: Int) -> String { "每种最多 \(v) 行" }
 static let translationColor = "译文颜色"
 static let originalColor = "原文颜色"
 static func opacity(_ v: Int) -> String { "背景不透明度 \(v)%" }
 static let previewOnly = "仅影响预览"
 static let translationFirst = "译文在上"
 static let position = "位置"

 // Diagnostics
 static let refresh = "刷新"
 static let export = "导出"
 static let diagUnavailable = "诊断日志暂时无法读取"
}
