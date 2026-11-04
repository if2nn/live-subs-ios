import SwiftUI
import ReplayKit

@main struct LiveSubsApp:App{
 var body:some Scene{WindowGroup{Home()}}
}
struct Home:View{
 @StateObject private var picture=Picture()
 @State private var key=Store.key()
 @State private var message=""
 @State private var testing=false
 @State private var tester:Soniox?
 @State private var documents:[URL]=[]
 @State private var share:[URL]=[]
 @State private var showShare=false
 var body:some View{
  NavigationStack{
   ScrollView{
    VStack(alignment:.leading,spacing:24){
     VStack(alignment:.leading,spacing:8){
      Text("LIVE / 双语").font(.caption.monospaced()).foregroundStyle(.orange)
      Text("听见世界\n看懂每一句").font(.largeTitle.weight(.bold))
      Text("原文在上，中文在下。声音只送往你的 Soniox 账户。").foregroundStyle(.secondary)
     }
     VideoSurface(picture:picture).frame(height:135).clipShape(RoundedRectangle(cornerRadius:14))
     HStack{Button("开启画中画"){picture.start()}.buttonStyle(.borderedProminent).tint(.orange);Button("关闭"){picture.stop()}}
     Text(picture.status).font(.caption).foregroundStyle(.secondary)
     Text("先开启画中画，再点下面的系统广播按钮。也可在控制中心长按录屏，选择双语字幕。麦克风可关闭。").font(.callout)
     BroadcastPicker().frame(width:56,height:56)
     Divider()
     Text("自己的 Soniox").font(.title3.bold())
     SecureField("API Key",text:$key).textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never).textFieldStyle(.roundedBorder)
     HStack{
      Button("保存到钥匙串"){
       do{try Store.save(key.trimmingCharacters(in:.whitespacesAndNewlines));message="已保存"}catch{message="保存失败 "+error.localizedDescription}
      }
      Button(testing ? "测试中…" : "测试连接"){test()}.disabled(testing || key.isEmpty)
     }.buttonStyle(.bordered)
     Text(message).font(.caption)
     Divider()
     HStack{Text("会话存档").font(.title3.bold());Spacer();Button("刷新"){refresh()}}
     ForEach(documents,id:\.self){url in
      Button{share=[url];showShare=true}label:{Label(url.lastPathComponent,systemImage:"square.and.arrow.up").font(.caption).lineLimit(2)}
     }
     Text("北京时间命名。广播结束后刷新，SRT、纯文本与未确认尾句恢复 JSON 会复制到本机文档目录。原文与译文独立断句，译文时间近似，不保证一一对应。录屏可能受播放器保护限制；画中画不保证能与其他视频画中画共存。").font(.footnote).foregroundStyle(.secondary)
    }.padding(24)
   }.background(Color(uiColor:.systemBackground)).navigationTitle("双语字幕").navigationBarTitleDisplayMode(.inline)
   .onAppear{refresh()}
   .sheet(isPresented:$showShare){ShareView(items:share)}
  }.preferredColorScheme(.dark)
 }
 private func test(){
  do{try Store.save(key.trimmingCharacters(in:.whitespacesAndNewlines))}catch{message="保存失败 "+error.localizedDescription;return}
  testing=true;message="连接并发送一秒静音验证鉴权"
  let c=Soniox();tester=c
  c.onStatus={s in DispatchQueue.main.async{message=s}}
  c.onMessage={obj in
   DispatchQueue.main.async{message="已收到 Soniox 响应，连接可用";testing=false;tester?.stop();tester=nil}
  }
  c.start(key)
  DispatchQueue.main.asyncAfter(deadline:.now()+1){c.send(Data(repeating:0,count:32000),voiced:false)}
  DispatchQueue.main.asyncAfter(deadline:.now()+9){
   if testing{message="未收到有效识别响应，请检查 Key、网络或余额";testing=false;c.stop();tester=nil}
  }
 }
 private func refresh(){
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
