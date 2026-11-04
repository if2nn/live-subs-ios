import SwiftUI
import ReplayKit
import Observation

@main struct LiveSubsApp:App{
 init(){Diagnostics.install()}
 var body:some Scene{WindowGroup{Home()}}
}
@MainActor @Observable final class HomeModel{
 var key=Store.key()
 var message=""
 var testing=false
 var documents:[URL]=[]
 var share:[URL]=[]
 var showShare=false
 private var tester:Soniox?
 var diagOpen=false
 var diagnostic:String{SharedSigning.diagnosticText}
 var previousDiagnostic:String{Diagnostics.previousSessionSummary}
 func exportDiagnostics(){
  guard let events=Diagnostics.exportURL,
        let text=try? String(contentsOf:events,encoding:.utf8) else{
   message="诊断日志暂时无法读取";return
  }
  let output=events.deletingLastPathComponent().appendingPathComponent("LiveSubs-diagnostics.txt")
  do{
   try (previousDiagnostic+"\n\n"+diagnostic+"\n\n"+text).write(to:output,atomically:true,encoding:.utf8)
   share=[output];showShare=true
  }catch{message="诊断导出失败"}
 }
 private var trimmed:String{key.trimmingCharacters(in:.whitespacesAndNewlines)}
 func saveKey(){
  do{try Store.save(trimmed);message=saveMessage()}catch{message="保存失败 "+error.localizedDescription}
 }
 private func saveMessage()->String{
  let scope=Store.saveScopeDescription
  let isPrivate=scope.contains("私有")
  return "已保存（"+scope+"）"+(isPrivate ? "。仅保存在主 App 私有钥匙串，广播扩展读不到，暂时不能广播。" : "")
 }
 func test(){
  let k=trimmed
  do{try Store.save(k)}catch{message="保存失败 "+error.localizedDescription;return}
  testing=true;message=saveMessage()+"。连接并发送一秒静音验证鉴权"
  let c=Soniox();tester=c
  c.onStatus={[weak self] s in Task{@MainActor in if self?.testing==true{self?.message=s}}}
  c.onFatal={[weak self] e in
   Task{@MainActor in
    guard let self,self.testing else{return}
    self.message="连接失败 "+e;self.testing=false;self.tester?.stop();self.tester=nil
   }
  }
  c.onMessage={[weak self] obj in
   let err=(obj["error_message"] as? String) ?? (obj["error"] as? String)
   let code=(obj["error_code"] as? Int).map(String.init)
   Task{@MainActor in
    guard let self,self.testing else{return}
    if err != nil || code != nil{
     self.message="Soniox 返回错误 "+(err ?? "code \(code!)");self.testing=false;self.tester?.stop();self.tester=nil;return
    }
    self.message="已收到 Soniox 响应，连接可用";self.testing=false;self.tester?.stop();self.tester=nil
   }
  }
  c.start(k)
  Task{@MainActor in
   try? await Task.sleep(for:.seconds(1))
   guard testing else{return}
   c.send(Data(repeating:0,count:32000),voiced:false)
   try? await Task.sleep(for:.seconds(8))
   if testing{message="未收到有效识别响应，请检查 Key、网络或余额";testing=false;c.stop();tester=nil}
  }
 }
 func refresh(){
  let fm=FileManager.default
  guard let dest=fm.urls(for:.documentDirectory,in:.userDomainMask).first else{return}
  if let source=Store.root?.appendingPathComponent("Sessions"),let urls=try? fm.contentsOfDirectory(at:source,includingPropertiesForKeys:nil){
   for url in urls where ["srt","json"].contains(url.pathExtension){
    if let data=try? Data(contentsOf:url){try? data.write(to:dest.appendingPathComponent(url.lastPathComponent),options:.atomic)
     if url.pathExtension=="srt",let s=String(data:data,encoding:.utf8){
      let lines=s.components(separatedBy:"\n").filter{!$0.contains(" --> ") && Int($0)==nil}
      try? lines.joined(separator:"\n").write(to:dest.appendingPathComponent(url.deletingPathExtension().lastPathComponent+".txt"),atomically:true,encoding:.utf8)
     }
    }
   }
  }
  documents=((try? fm.contentsOfDirectory(at:dest,includingPropertiesForKeys:nil)) ?? []).filter{["srt","txt","json"].contains($0.pathExtension)}.sorted{$0.lastPathComponent>$1.lastPathComponent}
 }
}
struct Home:View{
 @StateObject private var picture=Picture()
 @State private var model=HomeModel()
 var body:some View{
  content(model)
 }
 private func content(_ model:HomeModel)->some View{
  @Bindable var m=model
  return NavigationStack{
   ScrollView{
    VStack(alignment:.leading,spacing:20){
     VStack(alignment:.leading,spacing:6){
      Text("听见世界，看懂每一句").font(.largeTitle.weight(.bold))
      Text("原文在上，中文在下。声音只送往你的 Soniox 账户。").foregroundStyle(.secondary)
     }
     VideoSurface(picture:picture).frame(height:135).clipShape(RoundedRectangle(cornerRadius:20,style:.continuous))
     GlassCard{
      HStack{
       Button("开启画中画"){picture.start()}.glassProminentButton()
       Button("关闭"){picture.stop()}.glassButton()
      }
      Text(picture.status).font(.caption).foregroundStyle(.secondary)
      Text(m.previousDiagnostic).font(.caption2).textSelection(.enabled)
      HStack{
       Button("复制上次记录"){UIPasteboard.general.string=m.previousDiagnostic}.glassButton()
       Button("导出诊断"){m.exportDiagnostics()}.glassButton()
      }
      Text("关键操作前同步落盘，保留上次会话。日志不含 Key、字幕或音频；不能捕获所有崩溃。").font(.caption2).foregroundStyle(.secondary)
      Text("先开启画中画，再点系统广播按钮。也可在控制中心长按录屏，选择双语字幕。麦克风可关闭。").font(.callout)
      BroadcastPicker().frame(width:56,height:56)
     }
     GlassCard{
      Text("自己的 Soniox").font(.title3.bold())
      SecureField("API Key",text:$m.key).textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never).padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:12,style:.continuous))
      HStack{
       Button("保存到钥匙串"){
        m.saveKey()
       }.glassButton()
       Button(m.testing ? "测试中…" : "测试连接"){m.test()}.disabled(m.testing || m.key.isEmpty).glassButton()
      }
      Text("共享钥匙串不通时仍可保存和测试连接，但广播扩展读不到 Key，不能广播。").font(.caption).foregroundStyle(.secondary)
      if !m.message.isEmpty{Text(m.message).font(.caption).foregroundStyle(.secondary)}
      DisclosureGroup("诊断信息",isExpanded:$m.diagOpen){
       Text(m.diagnostic).font(.system(.caption2,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
       Button("复制诊断"){UIPasteboard.general.string=m.diagnostic}.glassButton()
      }.font(.callout)
     }
     GlassCard{
      HStack{Text("会话存档").font(.title3.bold());Spacer();Button("刷新"){m.refresh()}.glassButton()}
      ForEach(m.documents,id:\.self){url in
       Button{m.share=[url];m.showShare=true}label:{Label(url.lastPathComponent,systemImage:"square.and.arrow.up").font(.caption).lineLimit(2)}
      }
      Text("北京时间命名。广播结束后刷新，SRT、纯文本与未确认尾句恢复 JSON 会复制到本机文档目录。原文与译文独立断句，译文时间近似，不保证一一对应。录屏可能受播放器保护限制；画中画不保证能与其他视频画中画共存。").font(.footnote).foregroundStyle(.secondary)
     }
    }.padding(20)
   }.scrollContentBackground(.hidden).navigationTitle("双语字幕").navigationBarTitleDisplayMode(.large)
   .onAppear{m.refresh()}
   .sheet(isPresented:$m.showShare){ShareView(items:m.share)}
  }
 }
}
struct BroadcastPicker:UIViewRepresentable{
 func makeUIView(context:Context)->RPSystemBroadcastPickerView{
  let v=RPSystemBroadcastPickerView(frame:CGRect(x:0,y:0,width:56,height:56))
  v.preferredExtension=SharedSigning.broadcastIdentifier;v.showsMicrophoneButton=true;return v
 }
 func updateUIView(_ uiView:RPSystemBroadcastPickerView,context:Context){}
}
struct ShareView:UIViewControllerRepresentable{
 let items:[URL]
 func makeUIViewController(context:Context)->UIActivityViewController{UIActivityViewController(activityItems:items,applicationActivities:nil)}
 func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){}
}

struct GlassCard<Content:View>:View{
 @ViewBuilder var content:Content
 var body:some View{
  let stack=VStack(alignment:.leading,spacing:12){content}.frame(maxWidth:.infinity,alignment:.leading).padding(16)
  if #available(iOS 26,*){stack.glassEffect(.regular,in:RoundedRectangle(cornerRadius:24,style:.continuous))}
  else{stack.background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:24,style:.continuous))}
 }
}
extension View{
 @ViewBuilder func glassButton()->some View{
  if #available(iOS 26,*){self.buttonStyle(.glass)}else{self.buttonStyle(.bordered)}
 }
 @ViewBuilder func glassProminentButton()->some View{
  if #available(iOS 26,*){self.buttonStyle(.glassProminent)}else{self.buttonStyle(.borderedProminent)}
 }
}
