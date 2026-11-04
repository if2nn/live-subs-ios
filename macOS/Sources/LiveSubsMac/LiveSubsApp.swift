import SwiftUI
import AppKit

@main
struct LiveSubsMacApp: App {
 @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
 @State private var model = MacModel.shared
 var body: some Scene {
  WindowGroup("LiveSubs") {
   Studio(model: model)
    .frame(minWidth: 840, minHeight: 580)
    .preferredColorScheme(.dark)
    .alert("LiveSubs", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
     Button("好") { model.error = nil }
    } message: { Text(model.error ?? "") }
  }
  .defaultSize(width: 1120, height: 760)
  .commands {
   CommandGroup(after: .appInfo) {
    Button("显示悬浮字幕") { model.split = false; model.showPanel() }.keyboardShortcut("f", modifiers: [.command, .shift])
   }
  }
  Settings { Preferences(model: model).frame(width: 470).padding(24) }
 }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
 func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  let model = MacModel.shared
  if model.busy { return .terminateCancel }
  guard model.running else { return .terminateNow }
  Task {
   await model.stop()
   sender.reply(toApplicationShouldTerminate: true)
  }
  return .terminateLater
 }
}

struct Studio: View {
 @Bindable var model: MacModel
 var body: some View {
  NavigationSplitView {
   VStack(alignment: .leading, spacing: 20) {
    VStack(alignment: .leading, spacing: 5) {
     Text("LiveSubs").font(.system(size: 28, weight: .semibold, design: .rounded))
     Text("声音，成为文字。").foregroundStyle(.secondary)
    }.padding(.horizontal, 16).padding(.top, 24)
    Button { model.selectedHistory = nil } label: {
     Label("实时工作台", systemImage: "waveform")
      .frame(maxWidth: .infinity, alignment: .leading)
    }.buttonStyle(.bordered).padding(.horizontal, 12)
    Text("会话记录").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
    List(model.history, selection: $model.selectedHistory) { entry in
     VStack(alignment: .leading, spacing: 5) {
      Text(entry.title).font(.headline)
      Text(entry.preview.isEmpty ? "等待字幕" : entry.preview).font(.caption).lineLimit(2).foregroundStyle(.secondary)
      Text(Language.name(entry.source) + " / " + Language.name(entry.target)).font(.caption2).foregroundStyle(.tertiary)
     }.padding(.vertical, 7).tag(entry.id)
    }.listStyle(.sidebar)
   }.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 310)
  } detail: {
   VStack(spacing: 0) {
    header.padding(24)
    Divider()
    if model.split || model.selectedHistory != nil {
     TranscriptColumns(model: model)
    } else {
     ContentUnavailableView {
      Label("悬浮字幕已就位", systemImage: "pip")
     } description: {
      Text("切换到正在播放的内容。字幕窗可自由拖动和缩放。")
     } actions: {
      Button("重新显示字幕窗") { model.showPanel() }
     }
    }
    Divider()
    HStack {
     Circle().fill(model.running ? .green : .secondary).frame(width: 6, height: 6)
     Text(model.status).font(.caption).foregroundStyle(.secondary)
     Spacer()
     Menu("导出全文") {
      Button("纯文本 .txt") { model.export(srt: false) }
      Button("字幕 .srt") { model.export(srt: true) }
     }.disabled(model.viewed == nil)
    }.padding(16)
   }.background(Color(nsColor: .windowBackgroundColor))
  }
 }
 private var header: some View {
  VStack(alignment: .leading, spacing: 18) {
   HStack {
    VStack(alignment: .leading, spacing: 5) {
     Text(model.selectedHistory == nil ? "实时字幕" : "历史全文").font(.title2.weight(.semibold))
     Text("LIVE TRANSCRIPTION / TRANSLATION").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.6).foregroundStyle(.secondary)
    }
    Spacer()
    SettingsLink { Image(systemName: "slider.horizontal.3") }.help("语言、显示与 API Key")
    Button {
     Task { if model.running { await model.stop() } else { await model.start() } }
    } label: {
     Label(model.running ? "停止" : "开始聆听", systemImage: model.running ? "stop.fill" : "waveform")
    }.buttonStyle(.borderedProminent).tint(model.running ? .red : .accentColor).disabled(model.busy)
   }
   HStack {
    Picker("源语言", selection: $model.settings.languages.source) {
     ForEach(Language.sources) { Text($0.name).tag($0.code) }
    }.frame(maxWidth: 210).disabled(model.running || model.busy)
    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
    Picker("目标", selection: $model.settings.languages.target) {
     ForEach(Language.all) { Text($0.name).tag($0.code) }
    }.frame(maxWidth: 180).disabled(model.running || model.busy)
    Spacer()
    Picker("视图", selection: $model.split) {
     Text("左右分屏").tag(true); Text("悬浮窗").tag(false)
    }.pickerStyle(.segmented).frame(width: 170)
   }
  }
 }
}

struct TranscriptColumns: View {
 @Bindable var model: MacModel
 private var entry: HistoryEntry? { model.viewed }
 var body: some View {
  VStack(spacing: 0) {
   HStack {
    columnTitle("原文", detail: Language.name(entry?.source ?? model.settings.languages.source))
    Divider().frame(height: 20)
    columnTitle("译文", detail: Language.name(entry?.target ?? model.settings.languages.target))
   }.padding(.vertical, 16).padding(.horizontal, 24)
   Divider()
   ScrollViewReader { proxy in
    ScrollView {
     LazyVStack(alignment: .leading, spacing: 0) {
      if let entry {
       ForEach(entry.rows) { row in
        HStack(alignment: .top, spacing: 28) {
         lane(row.original, stamp: HistoryEntry.clock(row.startMS), translated: false)
         lane(row.translation, stamp: "", translated: true)
        }.padding(.vertical, 18)
        Divider().opacity(0.4)
       }
       HStack(alignment: .top, spacing: 28) {
        lane(entry.pendingOriginal, stamp: model.running && model.selectedHistory == nil ? "识别中" : "未定稿", translated: false)
        lane(entry.pendingTranslation, stamp: "", translated: true)
       }.padding(.vertical, 18)
      } else {
       ContentUnavailableView("等待声音", systemImage: "waveform", description: Text("开始聆听后，原文先出现，译文随后补上。\n音频仅发送到 Soniox，不在本机保存。"))
        .frame(maxWidth: .infinity).padding(.vertical, 80)
      }
      Color.clear.frame(height: 1).id("end")
     }.padding(.horizontal, 24)
    }
    .onChange(of: model.caption) { _, _ in
     if model.selectedHistory == nil { proxy.scrollTo("end", anchor: .bottom) }
    }
   }
   Text("译文按到达顺序展示，不保证逐句精确对齐。").font(.caption2).foregroundStyle(.tertiary).padding(10)
  }
 }
 private func columnTitle(_ text: String, detail: String) -> some View {
  HStack { Text(text).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
 }
 private func lane(_ text: String, stamp: String, translated: Bool) -> some View {
  VStack(alignment: .leading, spacing: 8) {
   if !stamp.isEmpty { Text(stamp).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
   Text(text.isEmpty ? " " : text)
    .font(.system(size: translated ? 21 : 17, weight: translated ? .medium : .regular))
    .foregroundStyle(translated ? .primary : .secondary)
    .textSelection(.enabled).lineSpacing(6)
  }.frame(maxWidth: .infinity, alignment: .leading)
 }
}

struct FloatingCaptions: View {
 @Bindable var model: MacModel
 var body: some View {
  let style = model.settings.style.normalized()
  VStack(spacing: 10) {
   if style.position == .bottom { Spacer(minLength: 0) }
   if style.translationFirst { translated(style); original(style) } else { original(style); translated(style) }
   if model.caption.original.isEmpty && model.caption.translated.isEmpty {
    Text(model.status).foregroundStyle(.gray).font(.callout)
   }
   if style.position == .top { Spacer(minLength: 0) }
  }
  .frame(maxWidth: .infinity, maxHeight: .infinity)
  .padding(24).background(Color.black.opacity(style.backgroundOpacity))
  .preferredColorScheme(.dark)
 }
 @ViewBuilder private func original(_ style: SubtitleStyle) -> some View {
  if model.settings.display != .translationOnly {
   Text(model.caption.originalLive ?? model.caption.original)
    .font(.system(size: style.fontSize * 0.65, weight: .medium))
    .foregroundStyle(color(style.originalColor))
    .multilineTextAlignment(.center).lineLimit(style.lines)
    .shadow(color: .black, radius: 2, y: 1)
  }
 }
 @ViewBuilder private func translated(_ style: SubtitleStyle) -> some View {
  if model.settings.display != .originalOnly {
   Text(model.caption.translatedLive ?? model.caption.translated)
    .font(.system(size: style.fontSize, weight: .semibold))
    .foregroundStyle(color(style.translationColor))
    .multilineTextAlignment(.center).lineLimit(style.lines)
    .shadow(color: .black, radius: 2, y: 1)
  }
 }
 private func color(_ value: CaptionColor) -> Color { let c = value.rgb; return Color(red: c.0, green: c.1, blue: c.2) }
}

struct Preferences: View {
 @Bindable var model: MacModel
 var body: some View {
  Form {
   Section("Soniox") {
    SecureField("API Key", text: $model.keyDraft)
     .textContentType(.password)
    Button("保存到钥匙串") { model.saveKey() }
    Text("Key 仅保存在本机钥匙串。清空并保存可移除。系统音频会发送给 Soniox 进行转写与翻译。").font(.caption).foregroundStyle(.secondary)
   }
   Section("悬浮字幕") {
    Picker("显示", selection: $model.settings.display) { ForEach(DisplayMode.allCases) { Text($0.title).tag($0) } }
    LabeledContent("译文字号") {
     Slider(value: $model.settings.style.fontSize, in: SubtitleStyle.fontRange, step: 1)
     Text(Int(model.settings.style.fontSize).description).monospacedDigit().frame(width: 28)
    }
    Stepper("每种语言最多 \(model.settings.style.lines) 行", value: $model.settings.style.lines, in: SubtitleStyle.lineRange)
    Picker("译文颜色", selection: $model.settings.style.translationColor) { ForEach(CaptionColor.allCases) { Text($0.title).tag($0) } }
    Picker("原文颜色", selection: $model.settings.style.originalColor) { ForEach(CaptionColor.allCases) { Text($0.title).tag($0) } }
    Picker("位置", selection: $model.settings.style.position) { ForEach(CaptionPosition.allCases) { Text($0.title).tag($0) } }
    Toggle("译文在上", isOn: $model.settings.style.translationFirst)
    Slider(value: $model.settings.style.backgroundOpacity, in: SubtitleStyle.opacityRange) { Text("背景不透明度") }
   }
   Section("隐私与权限") {
    Text("首次使用需授权屏幕与系统音频录制，不采集麦克风。历史全文保存在 Application Support/LiveSubsMac/History，可从主窗导出 TXT 或 SRT。").font(.caption).foregroundStyle(.secondary)
    Button("打开系统录制权限设置") {
     if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
   }
  }.formStyle(.grouped)
 }
}
