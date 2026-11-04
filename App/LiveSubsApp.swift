import SwiftUI
import ReplayKit
import Observation
import UIKit

@main struct LiveSubsApp: App {
 @State private var settings = SettingsStore()
 @State private var history = HistoryStore()
 @State private var pip = CaptionPiP()
 init() { Diagnostics.install() }
 var body: some Scene {
  WindowGroup {
   RootView()
    .environment(settings)
    .environment(history)
    .environment(pip)
    .preferredColorScheme(.dark)
  }
 }
}

struct RootView: View {
 @Environment(SettingsStore.self) private var settings
 @Environment(HistoryStore.self) private var history
 @Environment(CaptionPiP.self) private var pip
 @State private var tab = "live"
 var body: some View {
  TabView(selection: $tab) {
   Tab("字幕", systemImage: "captions.bubble", value: "live") { LiveView() }
   Tab("历史", systemImage: "clock.arrow.circlepath", value: "history") { HistoryListView() }
   Tab("设置", systemImage: "slider.horizontal.3", value: "settings") { SettingsView() }
   Tab("诊断", systemImage: "stethoscope", value: "diagnostics") { DiagnosticsView() }
  }
  .onAppear {
   pip.settings = settings.settings
   #if DEBUG
   if ProcessInfo.processInfo.arguments.contains("--ui-testing-seed-history") { history.seedForUITests() }
   #endif
   history.refresh()
  }
  .onChange(of: settings.settings) { _, value in
   settings.persist()
   pip.settings = value.normalized()
  }
  .onChange(of: pip.phase) { _, phase in if phase != .running { history.refresh() } }
 }
}

// MARK: - Live

struct LiveView: View {
 @Environment(CaptionPiP.self) private var pip
 @Environment(SettingsStore.self) private var settings
 var body: some View {
  NavigationStack {
   ScrollView {
    VStack(alignment: .leading, spacing: 18) {
     VStack(alignment: .leading, spacing: 6) {
      Text("听见世界，看懂每一句").font(.largeTitle.weight(.bold))
      Text("系统声音只送往你自己的 Soniox 账户。").foregroundStyle(.secondary)
     }
     VideoSurface(pip: pip)
      .aspectRatio(CGFloat(CaptionRenderer.width) / CGFloat(CaptionRenderer.height(for: settings.settings)), contentMode: .fit)
      .frame(maxWidth: .infinity)
      .background(Color.black)
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .accessibilityIdentifier("pip.preview")

     if pip.phase == .stopped || pip.phase == .stale {
      GlassCard {
       Label(pip.phase == .stopped ? "录屏已停止" : "录屏信号中断", systemImage: "exclamationmark.triangle.fill")
        .font(.headline).foregroundStyle(.yellow)
       Text("系统录屏结束后字幕不会再更新。点「重新开始」再次开启。").font(.callout)
       Button("重新开始") { pip.oneTapStart() }.buttonStyle(.glassProminent).accessibilityIdentifier("start.again")
      }.accessibilityIdentifier("broadcast.stopped.banner")
     }

     GlassCard {
      Button { pip.oneTapStart() } label: {
       Label(pip.phase == .running ? "开启悬浮字幕" : "开始", systemImage: "play.fill")
        .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
      }
      .buttonStyle(.glassProminent).tint(.orange)
      .disabled(!settings.hasKey)
      .accessibilityIdentifier("start.oneTap")
      if !settings.hasKey {
       Text("先到「设置」保存 Soniox Key。").font(.callout).foregroundStyle(.orange).accessibilityIdentifier("start.needsKey")
      }
      HStack(spacing: 12) {
       Button("只开悬浮字幕") { pip.arm(); pip.startPictureInPicture() }.buttonStyle(.glass).accessibilityIdentifier("pip.start")
       Button("关闭悬浮字幕") { pip.stopAll() }.buttonStyle(.glass).accessibilityIdentifier("pip.stop")
       Spacer()
       BroadcastPicker(launcher: pip.launcher).frame(width: 44, height: 44).accessibilityIdentifier("broadcast.picker")
      }
      Text(pip.status).font(.callout.weight(.medium)).accessibilityIdentifier("pip.status")
      Text(pip.captureStatus).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("capture.status")
     }

     GlassCard {
      Text("怎么用").font(.headline)
      Text("1. 点「开始」：悬浮字幕窗弹出，同时打开系统录屏面板。\n2. 在面板里选「双语字幕」，点「开始直播」。麦克风保持关闭。\n3. 回到视频 App 播放，字幕显示在悬浮窗里。\n4. 录屏停止后悬浮窗会提示，回到这里点「重新开始」。")
       .font(.callout).foregroundStyle(.secondary)
      Text("iOS 不允许 App 自己开始系统录屏，第 2 步必须由你在系统面板里点一下。受版权保护的视频，系统可能给录屏静音。画中画同一时间只能有一个，视频 App 自己的画中画会顶替字幕窗。")
       .font(.footnote).foregroundStyle(.secondary)
     }
    }.padding(20)
   }
   .navigationTitle("双语字幕").navigationBarTitleDisplayMode(.inline)
  }
 }
}

struct VideoSurface: UIViewRepresentable {
 let pip: CaptionPiP
 func makeUIView(context: Context) -> Surface {
  let v = Surface(); v.backgroundColor = .black; v.pip = pip
  return v
 }
 func updateUIView(_ uiView: Surface, context: Context) {}
 final class Surface: UIView {
  var pip: CaptionPiP?
  override func didMoveToWindow() {
   super.didMoveToWindow()
   if window != nil { pip?.attach(to: self) }
  }
  override func layoutSubviews() {
   super.layoutSubviews()
   pip?.layer.frame = bounds
  }
 }
}

struct BroadcastPicker: UIViewRepresentable {
 let launcher: BroadcastLauncher
 func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
  let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
  v.preferredExtension = SharedSigning.broadcastIdentifier
  v.showsMicrophoneButton = false
  launcher.picker = v
  return v
 }
 func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) { launcher.picker = uiView }
}

struct GlassCard<Content: View>: View {
 @ViewBuilder var content: Content
 var body: some View {
  VStack(alignment: .leading, spacing: 12) { content }
   .frame(maxWidth: .infinity, alignment: .leading)
   .padding(16)
   .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
 }
}

// MARK: - History

struct HistoryListView: View {
 @Environment(HistoryStore.self) private var history
 var body: some View {
  NavigationStack {
   Group {
    if history.entries.isEmpty {
     ContentUnavailableView("还没有字幕记录", systemImage: "text.bubble",
      description: Text("每次录屏的完整字幕会自动保存在这里。"))
      .accessibilityIdentifier("history.empty")
    } else {
     List {
      ForEach(history.entries) { entry in
       NavigationLink(value: entry.id) {
        VStack(alignment: .leading, spacing: 4) {
         Text(entry.title).font(.headline)
         Text(Language.name(entry.source) + " → " + Language.name(entry.target) + " · " + HistoryEntry.clock(entry.durationMS) + (entry.ended == nil ? " · 进行中" : ""))
          .font(.caption).foregroundStyle(.secondary)
         if !entry.preview.isEmpty { Text(entry.preview).font(.callout).lineLimit(2) }
        }
       }
       .accessibilityIdentifier("history.row")
      }
      .onDelete { offsets in offsets.map { history.entries[$0] }.forEach(history.delete) }
     }
    }
   }
   .navigationTitle("历史记录")
   .navigationDestination(for: String.self) { id in
    if let entry = history.entries.first(where: { $0.id == id }) { HistoryDetailView(entry: entry) }
   }
   .refreshable { history.refresh() }
   .onAppear { history.refresh() }
  }
 }
}

struct HistoryDetailView: View {
 let entry: HistoryEntry
 @Environment(HistoryStore.self) private var history
 @Environment(\.dismiss) private var dismiss
 @State private var mode: DisplayMode = .bilingual
 @State private var confirmDelete = false
 @State private var copied = false
 var body: some View {
  List {
   Section {
    Picker("显示", selection: $mode) {
     ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
    }.pickerStyle(.segmented).accessibilityIdentifier("history.mode")
   }
   Section {
    ForEach(entry.rows) { row in
     VStack(alignment: .leading, spacing: 4) {
      Text(HistoryEntry.clock(row.startMS)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      if mode != .translationOnly && !row.original.isEmpty { Text(row.original).foregroundStyle(.secondary) }
      if mode != .originalOnly && !row.translation.isEmpty { Text(row.translation).font(.body.weight(.medium)) }
     }
     .textSelection(.enabled)
    }
    if !entry.pendingOriginal.isEmpty || !entry.pendingTranslation.isEmpty {
     Text("未确认尾句：" + [entry.pendingOriginal, entry.pendingTranslation].filter { !$0.isEmpty }.joined(separator: " / "))
      .font(.caption).foregroundStyle(.secondary)
    }
   }
  }
  .accessibilityIdentifier("history.detail")
  .navigationTitle(entry.title)
  .toolbar {
   ToolbarItemGroup(placement: .topBarTrailing) {
    Button { UIPasteboard.general.string = entry.plainText(mode); copied = true } label: {
     Image(systemName: copied ? "checkmark" : "doc.on.doc")
    }.accessibilityIdentifier("history.copy").accessibilityLabel("复制")
    if let txt = history.exportFile(entry, mode: mode, srt: false), let srt = history.exportFile(entry, mode: mode, srt: true) {
     ShareLink(items: [txt, srt]) { Image(systemName: "square.and.arrow.up") }
      .accessibilityIdentifier("history.share").accessibilityLabel("分享")
    }
    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
     .accessibilityIdentifier("history.delete").accessibilityLabel("删除记录")
   }
  }
  .confirmationDialog("删除这条字幕记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
   Button("删除", role: .destructive) { history.delete(entry); dismiss() }.accessibilityIdentifier("history.delete.confirm")
  }
  .overlay(alignment: .bottom) {
   if copied {
    Text("已复制").font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
     .glassEffect(.regular, in: Capsule()).padding(.bottom, 24).accessibilityIdentifier("history.copied")
   }
  }
 }
}

// MARK: - Settings

struct SettingsView: View {
 @Environment(SettingsStore.self) private var store
 var body: some View {
  @Bindable var store = store
  NavigationStack {
   Form {
    Section {
     SecureField(store.hasKey ? "已保存（输入新 Key 替换）" : "Soniox API Key", text: $store.keyDraft)
      .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
      .accessibilityIdentifier("key.input")
     HStack {
      Button("保存 Key") { store.saveKey() }.buttonStyle(.glass)
       .disabled(store.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
       .accessibilityIdentifier("key.save")
      Button(store.testing ? "测试中…" : "测试连接") { store.testKey() }.buttonStyle(.glass)
       .disabled(store.testing || (!store.hasKey && store.keyDraft.isEmpty))
       .accessibilityIdentifier("key.test")
     }
     if !store.message.isEmpty { Text(store.message).font(.caption).accessibilityIdentifier("connection.status") }
     #if DEBUG
     if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
      Text("Stored length: \(store.storedKeyLength)").accessibilityIdentifier("key.persistedLength")
     }
     #endif
    } header: { Text("Soniox Key") } footer: {
     Text("Key 只存在本机钥匙串，不写入字幕、日志或诊断。")
    }

    Section("语言") {
     Picker("源语言", selection: $store.settings.languages.source) {
      ForEach(Language.sources) { Text($0.name).tag($0.code) }
     }.accessibilityIdentifier("settings.source")
     Picker("目标语言", selection: $store.settings.languages.target) {
      ForEach(Language.all) { Text($0.name).tag($0.code) }
     }.accessibilityIdentifier("settings.target")
     Text("语言在下一次开始录屏时生效。源语言与目标语言相同时只转写不翻译。").font(.caption).foregroundStyle(.secondary)
    }

    Section("显示") {
     Picker("模式", selection: $store.settings.display) {
      ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
     }.pickerStyle(.segmented).accessibilityIdentifier("settings.display")
     Text("当前：" + store.settings.display.title).font(.caption).foregroundStyle(.secondary)
      .accessibilityIdentifier("settings.display.value")
    }

    Section("字幕样式") {
     StylePreview(settings: store.settings).listRowInsets(EdgeInsets())
     VStack(alignment: .leading) {
      Text("字号 \(Int(store.settings.style.fontSize))")
      Slider(value: $store.settings.style.fontSize, in: SubtitleStyle.fontRange, step: 1)
       .accessibilityIdentifier("settings.fontSize")
     }
     Stepper("每种文字最多 \(store.settings.style.lines) 行", value: $store.settings.style.lines, in: SubtitleStyle.lineRange)
      .accessibilityIdentifier("settings.lines")
     Picker("译文颜色", selection: $store.settings.style.translationColor) {
      ForEach(CaptionColor.allCases) { Text($0.title).tag($0) }
     }.accessibilityIdentifier("settings.translationColor")
     Picker("原文颜色", selection: $store.settings.style.originalColor) {
      ForEach(CaptionColor.allCases) { Text($0.title).tag($0) }
     }.accessibilityIdentifier("settings.originalColor")
     VStack(alignment: .leading) {
      Text("背景不透明度 \(Int(store.settings.style.backgroundOpacity * 100))%")
      Slider(value: $store.settings.style.backgroundOpacity, in: SubtitleStyle.opacityRange)
       .accessibilityIdentifier("settings.opacity")
      Text("系统画中画窗口不能透明，悬浮字幕始终是黑底；这个设置用于 App 内预览的字幕底框。")
       .font(.caption2).foregroundStyle(.secondary)
     }
     Toggle("译文在上", isOn: $store.settings.style.translationFirst).accessibilityIdentifier("settings.order")
     Picker("位置", selection: $store.settings.style.position) {
      ForEach(CaptionPosition.allCases) { Text($0.title).tag($0) }
     }.pickerStyle(.segmented).accessibilityIdentifier("settings.position")
    }
   }
   .navigationTitle("设置")
  }
 }
}

/// SwiftUI preview of the caption style over a sample picture.
struct StylePreview: View {
 let settings: AppSettings
 private func color(_ c: CaptionColor) -> Color { let (r, g, b) = c.rgb; return Color(red: r, green: g, blue: b) }
 var body: some View {
  let s = settings.style.normalized()
  let original = Text("This is what the speaker said.").font(.system(size: s.fontSize * 0.55 * (settings.display == .originalOnly ? 1.28 : 1), weight: .medium)).foregroundStyle(color(s.originalColor))
  let translated = Text("这是说话人刚才说的话。").font(.system(size: s.fontSize * 0.7, weight: .semibold)).foregroundStyle(color(s.translationColor))
  ZStack(alignment: s.position == .top ? .top : (s.position == .center ? .center : .bottom)) {
   LinearGradient(colors: [.indigo, .teal, .orange.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
   VStack(spacing: 4) {
    switch settings.display {
    case .originalOnly: original
    case .translationOnly: translated
    case .bilingual:
     if s.translationFirst { translated; original } else { original; translated }
    }
   }
   .multilineTextAlignment(.center).lineLimit(s.lines)
   .padding(.horizontal, 12).padding(.vertical, 8)
   .background(Color.black.opacity(s.backgroundOpacity), in: RoundedRectangle(cornerRadius: 8))
   .padding(10)
  }
  .frame(height: 150)
  .accessibilityIdentifier("settings.preview")
 }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
 @State private var text = ""
 @State private var share: URL?
 @State private var message = ""
 private func reload() {
  text = Diagnostics.previousSessionSummary + "\n\n" + SharedSigning.diagnosticText + "\n\n" + CaptureIPC.diagnosticText
 }
 var body: some View {
  NavigationStack {
   ScrollView {
    VStack(alignment: .leading, spacing: 14) {
     HStack {
      Button("刷新") { reload() }.buttonStyle(.glass)
      Button("复制") { UIPasteboard.general.string = text; message = "已复制" }.buttonStyle(.glass).accessibilityIdentifier("diag.copy")
      Button("导出") {
       if let url = Diagnostics.exportURL { share = url } else { message = "诊断日志暂时无法读取" }
      }.buttonStyle(.glass).accessibilityIdentifier("diag.export")
      if let share { ShareLink(item: share) { Image(systemName: "square.and.arrow.up") } }
     }
     if !message.isEmpty { Text(message).font(.caption) }
     Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("diag.text")
     Text("诊断只含固定事件名、计数、音频格式和电平，不含 Key、字幕原文或音频。").font(.caption2).foregroundStyle(.secondary)
    }.padding(20)
   }
   .navigationTitle("诊断")
   .onAppear { reload() }
  }
 }
}
