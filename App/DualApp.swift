import SwiftUI
import ReplayKit
import Observation
import UIKit

extension AppearanceMode {
 /// `nil` lets the system decide; preview 6 default is `.system`.
 var colorScheme: ColorScheme? {
  switch self { case .system: nil; case .light: .light; case .dark: .dark }
 }
}

@main struct DualApp: App {
 @State private var settings = SettingsStore()
 @State private var history = HistoryStore()
 @State private var pip = CaptionPiP()
 @State private var interpret = InterpretSession()
 @State private var transcribe = TranscribeStore()
 init() { Diagnostics.install() }
 var body: some Scene {
  WindowGroup {
   RootView()
    .environment(settings)
    .environment(history)
    .environment(pip)
    .environment(interpret)
    .environment(transcribe)
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
   Tab(S.tabCaptions, systemImage: "captions.bubble", value: "live") { LiveView(openSettings: { tab = "settings" }) }
   Tab(S.tabInterpret, systemImage: "waveform.and.mic", value: "interpret") { InterpretView() }
   Tab(S.tabTranscribe, systemImage: "doc.text", value: "transcribe") { TranscribeView() }
   Tab(S.tabSettings, systemImage: "gearshape", value: "settings") { SettingsView() }
  }
  .onAppear {
   pip.settings = settings.settings
   #if DEBUG
   if ProcessInfo.processInfo.arguments.contains("--ui-testing-seed-history") { history.seedForUITests() }
   if ProcessInfo.processInfo.arguments.contains("--ui-testing-seed-caption") { pip.enableCaptionFixture() }
   #endif
   history.refresh()
  }
  .onChange(of: settings.settings) { _, value in
   settings.persist()
   pip.settings = value.normalized()
  }
  .onChange(of: pip.phase) { _, phase in if phase != .running { history.refresh() } }
  .preferredColorScheme(settings.settings.appearance.colorScheme)
 }
}

// MARK: - Live

struct LiveView: View {
 var openSettings: () -> Void = {}
 @Environment(CaptionPiP.self) private var pip
 @Environment(InterpretSession.self) private var interpret
 @State private var captionsBlocked = false
 @Environment(SettingsStore.self) private var settings
 var body: some View {
  NavigationStack {
   ScrollView {
    VStack(alignment: .leading, spacing: 18) {
     VideoSurface(pip: pip)
      .aspectRatio(CGFloat(CaptionCanvas.aspect(for: settings.settings)), contentMode: .fit)
      .frame(maxWidth: .infinity)
      .background(Color.black)
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .accessibilityIdentifier("pip.preview")
     #if DEBUG
     if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
      Text(pip.frameLabel).font(.caption2.monospaced()).foregroundStyle(.secondary).accessibilityIdentifier("pip.frame.size")
     }
     #endif

     if pip.phase == .stopped || pip.phase == .stale {
      SectionCard {
       Label(pip.phase == .stopped ? S.captureStopped : S.captureStale, systemImage: "exclamationmark.triangle.fill")
        .font(.headline).foregroundStyle(.yellow)
       Button(S.restart) { pip.oneTapStart() }.buttonStyle(.glassProminent).accessibilityIdentifier("start.again")
      }.accessibilityIdentifier("broadcast.stopped.banner")
     }

     SectionCard {
      Button {
       // 同声传译 needs .playAndRecord; captions keep PiP alive with .playback (plan §6).
       if interpret.isRunning { captionsBlocked = true } else { captionsBlocked = false; pip.oneTapStart() }
      } label: {
       Label(S.start, systemImage: "play.fill")
        .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
      }
      .buttonStyle(.glassProminent).tint(.orange)
      .disabled(!settings.hasKey)
      .accessibilityIdentifier("start.oneTap")
      if captionsBlocked && interpret.isRunning {
       Text(S.captionsBusy).font(.callout).foregroundStyle(.orange).accessibilityIdentifier("start.interpretBusy")
      }
      if !settings.hasKey {
       HStack {
        Text(S.noKey).font(.callout).foregroundStyle(.orange).accessibilityIdentifier("start.needsKey")
        Button(S.goToSettings) { openSettings() }.font(.callout).accessibilityIdentifier("start.goToSettings")
       }
      }
      HStack(spacing: 12) {
       Button(S.pipOnly) { guard !interpret.isRunning else { captionsBlocked = true; return }; pip.arm(); pip.startPictureInPicture() }.buttonStyle(.glass).accessibilityIdentifier("pip.start")
       Button(S.stop) { pip.stopAll() }.buttonStyle(.glass).accessibilityIdentifier("pip.stop")
       Spacer()
       BroadcastPicker(launcher: pip.launcher).frame(width: 44, height: 44).accessibilityIdentifier("broadcast.picker")
      }
      Text(pip.status).font(.callout.weight(.medium)).accessibilityIdentifier("pip.status")
      Text(pip.captureStatus).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("capture.status")
     }

     NavigationLink { ManualView() } label: {
      Label(S.manualLink, systemImage: "book")
     }.accessibilityIdentifier("live.manual")
    }.padding(20)
   }
   .navigationTitle(S.titleCaptions).navigationBarTitleDisplayMode(.inline)
   .toolbar { RecordsToolbarItem() }
  }
 }
}

/// Top-right 「记录」 entry on each feature page (D1 default).
struct RecordsToolbarItem: ToolbarContent {
 var body: some ToolbarContent {
  ToolbarItem(placement: .topBarTrailing) {
   NavigationLink { RecordsView() } label: { Text(S.records) }
    .accessibilityIdentifier("records.open")
  }
 }
}

// 同声传译: Interpret.swift. 音频转录: Transcribe.swift.

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

/// Content-layer card. Per the HIG Materials guidance, Liquid Glass is kept for
/// controls and navigation (glass buttons, tab bar, toolbars); content sits on
/// a standard grouped background, not on glass.
struct SectionCard<Content: View>: View {
 @ViewBuilder var content: Content
 var body: some View {
  VStack(alignment: .leading, spacing: 12) { content }
   .frame(maxWidth: .infinity, alignment: .leading)
   .padding(16)
   .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
 }
}

// MARK: - History

/// All records. Pushed from each page's 「记录」 and from 设置 → 记录,
/// so it owns no NavigationStack of its own.
struct RecordsView: View {
 @Environment(HistoryStore.self) private var history
 var body: some View {
   Group {
    if history.entries.isEmpty {
     ContentUnavailableView(S.recordsEmpty, systemImage: "text.bubble")
      .accessibilityIdentifier("history.empty")
    } else {
     List {
      ForEach(history.entries) { entry in
       // View-based link: RecordsView is itself pushed from several stacks, and a
       // value link there found no navigationDestination on the iOS 27 simulator.
       NavigationLink { HistoryDetailView(entry: entry) } label: {
        VStack(alignment: .leading, spacing: 4) {
         Text(entry.title).font(.headline)
         Text(Language.name(entry.source) + " → " + Language.name(entry.target) + " · " + HistoryEntry.clock(entry.durationMS) + (entry.ended == nil ? S.inProgress : ""))
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
   .navigationTitle(S.titleRecords)
   .refreshable { history.refresh() }
   .onAppear { history.refresh() }
 }
}

struct HistoryDetailView: View {
 let entry: HistoryEntry
 @Environment(HistoryStore.self) private var history
 @Environment(\.dismiss) private var dismiss
 @State private var mode: DisplayMode = .bilingual
 @State private var confirmDelete = false
 @State private var copied = false
 @State private var exports: [URL] = []
 var body: some View {
  List {
   Section {
    Picker(S.display, selection: $mode) {
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
     Text(S.pending + [entry.pendingOriginal, entry.pendingTranslation].filter { !$0.isEmpty }.joined(separator: " / "))
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
    }.accessibilityIdentifier("history.copy").accessibilityLabel(S.copy)
    ShareLink(items: exports) { Image(systemName: "square.and.arrow.up") }
     .disabled(exports.isEmpty)
     .accessibilityIdentifier("history.share").accessibilityLabel(S.share)
    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
     .accessibilityIdentifier("history.delete").accessibilityLabel(S.deleteRecord)
   }
  }
  // Export files are written once per display mode, not on every body pass.
  .task(id: mode) {
   exports = [history.exportFile(entry, mode: mode, srt: false), history.exportFile(entry, mode: mode, srt: true)].compactMap { $0 }
  }
  .confirmationDialog(S.deleteRecordConfirm, isPresented: $confirmDelete, titleVisibility: .visible) {
   Button(S.delete, role: .destructive) { history.delete(entry); dismiss() }.accessibilityIdentifier("history.delete.confirm")
  }
  .overlay(alignment: .bottom) {
   if copied {
    Text(S.copied).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
     .background(.regularMaterial, in: Capsule()).padding(.bottom, 24).accessibilityIdentifier("history.copied")
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
    Section(S.sectionAccount) {
     NavigationLink { APIKeyView() } label: {
      LabeledContent(S.titleAPIKey, value: store.hasKey ? S.keySaved : S.keyMissing)
     }.accessibilityIdentifier("settings.apiKey")
    }

    Section {
     Picker(S.appearance, selection: $store.settings.appearance) {
      ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
     }.pickerStyle(.segmented).accessibilityIdentifier("settings.appearance")
    } header: { Text(S.sectionAppearance) } footer: { Text(S.appearanceFooter) }

    AppIconSection()

    Section {
     Picker(S.sourceLanguage, selection: $store.settings.languages.source) {
      ForEach(Language.sources) { Text($0.name).tag($0.code) }
     }.accessibilityIdentifier("settings.source")
     Picker(S.targetLanguage, selection: $store.settings.languages.target) {
      ForEach(Language.all) { Text($0.name).tag($0.code) }
     }.accessibilityIdentifier("settings.target")
     Picker(S.mode, selection: $store.settings.display) {
      ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
     }.pickerStyle(.segmented).accessibilityIdentifier("settings.display")
     Text(S.current + store.settings.display.title).font(.caption).foregroundStyle(.secondary)
      .accessibilityIdentifier("settings.display.value")
     Picker(S.pipShape, selection: $store.settings.pipShape) {
      ForEach(PiPShape.allCases) { Text($0.title).tag($0) }
     }.pickerStyle(.segmented).accessibilityIdentifier("settings.pipShape")
     NavigationLink(S.titleStyle) { CaptionStyleView() }.accessibilityIdentifier("settings.styleLink")
    } header: { Text(S.sectionCaptions) } footer: { Text(S.languageFooter) }

    Section(S.sectionData) {
     NavigationLink(S.titleRecords) { RecordsView() }.accessibilityIdentifier("settings.records")
    }

    Section(S.sectionHelp) {
     NavigationLink(S.titleManual) { ManualView() }.accessibilityIdentifier("settings.manual")
     NavigationLink(S.titleDiagnostics) { DiagnosticsView() }.accessibilityIdentifier("settings.diagnostics")
    }

    Section(S.sectionAbout) {
     LabeledContent(S.version, value: Self.version).accessibilityIdentifier("settings.version")
    }
   }
   .navigationTitle(S.titleSettings)
  }
 }
 static var version: String {
  let info = Bundle.main.infoDictionary
  return (info?["CFBundleShortVersionString"] as? String ?? "") + " (" + (info?["CFBundleVersion"] as? String ?? "") + ")"
 }
}

/// 设置 → API Key. Keychain entry (service, account, access group) unchanged.
struct APIKeyView: View {
 @Environment(SettingsStore.self) private var store
 @FocusState private var keyFocused: Bool
 var body: some View {
  @Bindable var store = store
  Form {
   Section {
    SecureField(store.hasKey ? S.keyPlaceholderSaved : S.keyPlaceholder, text: $store.keyDraft)
     .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
     .focused($keyFocused).submitLabel(.done).onSubmit { keyFocused = false }
     .accessibilityIdentifier("key.input")
    HStack {
     Button(S.saveKey) { store.saveKey(); keyFocused = false }.buttonStyle(.glass)
      .disabled(store.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier("key.save")
     Button(store.testing ? S.testing : S.testConnection) { store.testKey() }.buttonStyle(.glass)
      .disabled(store.testing || (!store.hasKey && store.keyDraft.isEmpty))
      .accessibilityIdentifier("key.test")
    }
    if !store.message.isEmpty { Text(store.message).font(.caption).accessibilityIdentifier("connection.status") }
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
     Text("Stored length: \(store.storedKeyLength)").accessibilityIdentifier("key.persistedLength")
    }
    #endif
   } header: { Text(S.keyHeader) }
  }
  .scrollDismissesKeyboard(.interactively)
  .navigationTitle(S.titleAPIKey)
 }
}

/// 设置 → 字幕样式.
struct CaptionStyleView: View {
 @Environment(SettingsStore.self) private var store
 var body: some View {
  @Bindable var store = store
  Form {
   Section {
    StylePreview(settings: store.settings).listRowInsets(EdgeInsets())
    VStack(alignment: .leading) {
     Text(S.fontSize(Int(store.settings.style.fontSize)))
     Slider(value: $store.settings.style.fontSize, in: SubtitleStyle.fontRange, step: 1)
      .accessibilityIdentifier("settings.fontSize")
    }
    Stepper(S.linesPerLane(store.settings.style.lines), value: $store.settings.style.lines, in: SubtitleStyle.lineRange)
     .accessibilityIdentifier("settings.lines")
    Picker(S.translationColor, selection: $store.settings.style.translationColor) {
     ForEach(CaptionColor.allCases) { Text($0.title).tag($0) }
    }.accessibilityIdentifier("settings.translationColor")
    Picker(S.originalColor, selection: $store.settings.style.originalColor) {
     ForEach(CaptionColor.allCases) { Text($0.title).tag($0) }
    }.accessibilityIdentifier("settings.originalColor")
    VStack(alignment: .leading) {
     Text(S.opacity(Int(store.settings.style.backgroundOpacity * 100)))
     Slider(value: $store.settings.style.backgroundOpacity, in: SubtitleStyle.opacityRange)
      .accessibilityIdentifier("settings.opacity")
     Text(S.previewOnly)
      .font(.caption2).foregroundStyle(.secondary)
    }
    Toggle(S.translationFirst, isOn: $store.settings.style.translationFirst).accessibilityIdentifier("settings.order")
    Picker(S.position, selection: $store.settings.style.position) {
     ForEach(CaptionPosition.allCases) { Text($0.title).tag($0) }
    }.pickerStyle(.segmented).accessibilityIdentifier("settings.position")
   }
  }
  .navigationTitle(S.titleStyle)
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
   ScrollView {
    VStack(alignment: .leading, spacing: 14) {
     HStack {
      Button(S.refresh) { reload() }.buttonStyle(.glass)
      Button(S.copy) { UIPasteboard.general.string = text; message = S.copied }.buttonStyle(.glass).accessibilityIdentifier("diag.copy")
      Button(S.export) {
       if let url = Diagnostics.exportURL { share = url } else { message = S.diagUnavailable }
      }.buttonStyle(.glass).accessibilityIdentifier("diag.export")
      if let share { ShareLink(item: share) { Image(systemName: "square.and.arrow.up") } }
     }
     if !message.isEmpty { Text(message).font(.caption) }
     Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("diag.text")
    }.padding(20)
   }
   .navigationTitle(S.titleDiagnostics)
   .onAppear { reload() }
 }
}
