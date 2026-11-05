import SwiftUI

/// 设置 → 使用手册 (plan §3.5). Local static content, no network.
/// Explanations removed from pages in S2 live here.
struct ManualChapter: Identifiable {
 let id: String
 let title: String
 let sections: [(heading: String, body: String)]
}

enum Manual {
 static let chapters: [ManualChapter] = [
  ManualChapter(id: "setup", title: "准备", sections: [
   ("获取 API Key", "在 Soniox 控制台创建 API Key。Dual 只使用 Soniox，音频直接发往该 Key 所属的账户。"),
   ("保存与测试", "设置 → API Key：粘贴后点「保存」，再点「测试连接」。测试会建立一次连接并发送一秒静音，显示连接是否可用。")
  ]),
  ManualChapter(id: "captions", title: "字幕", sections: [
   ("开始步骤", "1. 在「字幕」页点「开始」：悬浮窗弹出，同时打开系统录屏面板。\n2. 在面板里选「Dual」，点「开始直播」。麦克风保持关闭。\n3. 回到视频 App 播放，字幕显示在悬浮窗里。\n4. 录屏停止后悬浮窗会提示，回到「字幕」页点「重新开始」。"),
   ("为什么要在系统面板里点", "iOS 不允许 App 自己开始系统录屏，「开始直播」必须在系统面板里手动点一次。"),
   ("静音的视频", "受版权保护的视频，系统可能给录屏静音，此时不会有字幕。"),
   ("画中画只能有一个", "同一时间只能有一个画中画。视频 App 自己的画中画会顶替字幕悬浮窗。"),
   ("经典与长条", "经典：高度随字号与行数变化。长条：宽而扁的字幕条，约两行双语。在 设置 → 字幕 → 悬浮窗形状 切换。"),
   ("黑底", "系统画中画窗口不能透明，悬浮字幕始终是黑底。字幕样式里的背景不透明度只影响 App 内预览。"),
   ("语言", "语言在下一次开始时生效。源语言与目标语言相同时只转写，不翻译。")
  ]),
  ManualChapter(id: "interpret", title: "同声传译", sections: [
   ("对话与自己听", "对话：面对面两人使用，上下分栏，双向翻译，对面一栏可翻转 180°。自己听：原文与译文逐句交替显示。"),
   ("后台与锁屏", "运行中屏幕保持常亮；锁屏或切到后台后继续识别，系统会显示麦克风指示。"),
   ("与字幕互斥", "同声传译与字幕不能同时运行，开始其中一个前需先停止另一个。")
  ]),
  ManualChapter(id: "transcribe", title: "音频转录", sections: [
   ("支持的格式", "aac、aiff、amr、asf、flac、mp3、ogg、wav、webm、m4a、mp4。其他容器（如 mov）先在本机转换为 m4a 再上传。"),
   ("时长上限", "单个文件最长 300 分钟。"),
   ("语言选项", "自动：自动识别。单一：只指定一种语言。多种：指定可能出现的几种语言。仅识别所选语言：只输出所选语言。"),
   ("文件保存", "文件上传到自己的 Soniox 账户处理，完成后由 Dual 删除；未删除的文件 30 天后由 Soniox 自动删除。")
  ]),
  ManualChapter(id: "records", title: "记录与导出", sections: [
   ("记录", "每次字幕、同传、转录的结果都保存在「记录」中，各页右上角和 设置 → 记录 均可进入。"),
   ("导出", "记录详情页可复制或分享为 txt、srt 文件，可存入「文件」App。")
  ]),
  ManualChapter(id: "privacy", title: "隐私", sections: [
   ("音频去向", "音频只发往自己的 Soniox 账户。"),
   ("API Key", "Key 只存在本机钥匙串，不写入字幕、记录、日志或诊断。"),
   ("诊断", "诊断只含固定事件名、计数、音频格式和电平，不含 Key、字幕原文或音频。")
  ]),
  ManualChapter(id: "faq", title: "常见问题", sections: [
   ("Key 无效", "设置 → API Key 重新粘贴并测试连接。"),
   ("余额不足", "在 Soniox 控制台充值后重试。"),
   ("并发超限", "同一个 Key 同时进行的识别过多，稍后重试或停止其他设备上的使用。"),
   ("录屏被中断", "来电、锁屏或系统资源不足可能中断录屏。回到「字幕」页点「重新开始」。")
  ])
 ]
}

struct ManualView: View {
 var body: some View {
  List(Manual.chapters) { chapter in
   NavigationLink(chapter.title) { ManualChapterView(chapter: chapter) }
    .accessibilityIdentifier("manual.chapter." + chapter.id)
  }
  .navigationTitle(S.titleManual)
  .accessibilityIdentifier("manual.list")
 }
}

struct ManualChapterView: View {
 let chapter: ManualChapter
 var body: some View {
  List {
   ForEach(Array(chapter.sections.enumerated()), id: \.offset) { _, section in
    Section(section.heading) { Text(section.body).font(.callout) }
   }
  }
  .navigationTitle(chapter.title)
 }
}
