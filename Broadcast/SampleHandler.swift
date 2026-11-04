import ReplayKit
import AVFoundation

// ReplayKit serializes audio callbacks; transcript/archive state is confined to client.queue.
// Only immutable PCM Data crosses into the socket queue.
final class SampleHandler:RPBroadcastSampleHandler, @unchecked Sendable{
 private lazy var client=Soniox()
 private var converter:AVAudioConverter?
 private var inputFormat:AVAudioFormat?
 private lazy var outputFormat=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
 private var transcript=Transcript()
 private var state=Caption()
 private var archive:URL?
 private var index=0
 private var recoveryURL:URL?
 private var unarchived:[Segment]=[]
 private var offset=0
 private var began=Date()
 private var lastWrite=Date.distantPast
 // Accessed only on client.queue, including conversion result reporting.
 private var conversionFailures=0
 private var terminalStatus:String?
 override func broadcastStarted(withSetupInfo setupInfo:[String:NSObject]?){
  CaptureIPC.extensionEntered()
  CaptureIPC.extensionDiscovered()
  CaptureIPC.event(.started)
  began=Date()
  guard let root=Store.root else{CaptureIPC.event(.fatal,code:1,domain:"LiveSubs");finishBroadcastWithError(NSError(domain:"App Group 不可用",code:1));return}
  let keyResult=Store.keyReadResult()
  CaptureIPC.keyRead(success:keyResult.success,status:keyResult.status)
  let key=keyResult.value
  guard keyResult.success else{CaptureIPC.event(.fatal,code:2,domain:"LiveSubs");finishBroadcastWithError(NSError(domain:"请先保存 API Key，检查共享钥匙串签名",code:2));return}
  let dir=root.appendingPathComponent("Sessions")
  try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  let f=DateFormatter();f.timeZone=TimeZone(identifier:"Asia/Shanghai");f.dateFormat="yyyy-MM-dd_HH-mm-ss"
  archive=dir.appendingPathComponent(f.string(from:began)+"_"+UUID().uuidString.prefix(6)+".srt")
  FileManager.default.createFile(atPath:archive!.path,contents:nil,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
  recoveryURL=archive?.deletingPathExtension().appendingPathExtension("recovery.json")
  client.onEvent={event,code,domain in CaptureIPC.event(event,code:code,domain:domain)}
  client.onMessage={[weak self] obj in
   guard let self=self,self.terminalStatus == nil else{return}
   let tokens=obj["tokens"] as? [[String:Any]]
   let arrival=max(0,Int(Date().timeIntervalSince(self.began)*1000)-self.offset)
   if let tokens=tokens,!tokens.isEmpty {self.add(self.transcript.ingest(tokens,arrivalMS:arrival))}
   self.state=self.transcript.caption
   self.persist()
   self.writeSegments()
   self.publish(true)
  }
  client.onFatal={[weak self] message in self?.fail(message)}
  client.onStatus={[weak self] s in
   guard let self=self,self.terminalStatus == nil else{return}
   self.state.status=s;self.persist();self.publish(true)
  }
  client.onReconnect={[weak self] in
   guard let self=self,self.terminalStatus == nil else{return}
   self.add(self.transcript.finishFinals())
   self.persist();self.writeSegments()
   // Keep uncertain partials in the old recovery snapshot, never call them final.
   let arrival=Int(Date().timeIntervalSince(self.began)*1000)
   if let url=self.recoveryURL,let data=try? JSONEncoder().encode(Recovery(transcript:self.transcript,unarchived:self.unarchived,offset:self.offset,status:"重连前未确认尾句")){
    do{try data.write(to:url.deletingPathExtension().appendingPathExtension(UUID().uuidString+".json"),options:.atomic)}
    catch{self.state.status="恢复快照写入失败";self.publish(true)}
   }
   // Retry any failed archive writes before changing the timestamp origin.
   // Pending cues are absolute-timed when created, not when written.
   self.transcript=Transcript();self.offset=arrival
  }
  client.start(key)
 }
 // Called only on client.queue. Persist before asking ReplayKit to end; invoke
 // the framework off the queue so broadcastFinished can safely synchronize it.
 private func fail(_ message:String){
  guard terminalStatus == nil else{return}
  CaptureIPC.event(.fatal,code:3,domain:"LiveSubs")
  terminalStatus=message
  add(transcript.finishFinals())
  state.status=message;persist();writeSegments()
  state.status=message;persist();publish(true)
  client.stop()
  DispatchQueue.global().async{[self] in
   finishBroadcastWithError(NSError(domain:"LiveSubs",code:3,userInfo:[NSLocalizedDescriptionKey:message]))
  }
 }
 private func conversionFailed(){
  CaptureIPC.event(.conversionError)
  client.queue.async{[self] in
   guard terminalStatus == nil else{return}
   conversionFailures+=1
   state.status="音频转换失败（\(conversionFailures)/3）";persist();publish(true)
   if conversionFailures>=3{fail("音频连续转换失败，广播已停止")}
  }
 }
 private func publish(_ force:Bool){
  if force || Date().timeIntervalSince(lastWrite)>0.12{state.updated=Date();Store.publish(state);lastWrite=Date()}
 }
 private func persist(){
  guard let url=recoveryURL else{return}
  do{
   let snapshot=Recovery(transcript:transcript,unarchived:unarchived,offset:offset,status:state.status)
   try JSONEncoder().encode(snapshot).write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
  }catch{state.status="恢复快照写入失败"}
 }
 private func writeSegments(){
  guard !unarchived.isEmpty,let url=archive else{return}
  // Atomically rewrite the short text archive to avoid partial append duplicates.
  do{
   let previous=try String(contentsOf:url,encoding:.utf8)
   var text=previous
   for (position,cue) in unarchived.enumerated(){
    let label=cue.lane == .original ? "原文" : "译文（时间近似）"
    text += SRT.cue(index+position+1,cue.start,cue.end,label+" "+cue.text,"")
   }
   try text.write(to:url,atomically:true,encoding:.utf8)
   index += unarchived.count;unarchived.removeAll();persist()
  }catch{state.status="存档写入失败，待恢复快照";persist()}
 }
 private func add(_ segments:[Segment]){
  unarchived += segments.map{cue in
   var absolute=cue;absolute.start += offset;absolute.end += offset;return absolute
  }
 }
 override func processSampleBuffer(_ sampleBuffer:CMSampleBuffer,with sampleBufferType:RPSampleBufferType){
  guard sampleBufferType == .audioApp else{return}
  CaptureIPC.audio(frames:CMSampleBufferGetNumSamples(sampleBuffer))
  autoreleasepool{convert(sampleBuffer)}
 }
 private func convert(_ sample:CMSampleBuffer){
  guard let desc=CMSampleBufferGetFormatDescription(sample) else{conversionFailed();return}
  let format=AVAudioFormat(cmAudioFormatDescription:desc)
  let frames=CMSampleBufferGetNumSamples(sample)
  guard frames>0 else{return} // A zero-frame callback is not a conversion failure.
  guard let input=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)) else{conversionFailed();return}
  input.frameLength=AVAudioFrameCount(frames)
  guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,at:0,frameCount:Int32(frames),into:input.mutableAudioBufferList)==noErr else{conversionFailed();return}
  if inputFormat != format{converter=AVAudioConverter(from:format,to:outputFormat);inputFormat=format}
  guard let converter=converter,let output=AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:AVAudioFrameCount(Double(frames)*16000/format.sampleRate+32)) else{conversionFailed();return}
  var supplied=false;var error:NSError?
  let result=converter.convert(to:output,error:&error){_,flag in
   if supplied{flag.pointee = .noDataNow;return nil}
   supplied=true;flag.pointee = .haveData;return input
  }
  guard error==nil,result != .error else{conversionFailed();return}
  // A converter can buffer input and legitimately produce no output yet.
  guard output.frameLength>0 else{
   client.queue.async{self.conversionFailures=0};return
  }
  guard let p=output.int16ChannelData?[0] else{conversionFailed();return}
  client.queue.async{self.conversionFailures=0}
  let n=Int(output.frameLength);var peak:Int32=0
  for i in 0..<n{peak=max(peak,abs(Int32(p[i])))}
  client.send(Data(bytes:p,count:n*2),voiced:peak>300)
 }
 override func broadcastPaused(){CaptureIPC.event(.paused);client.queue.async{self.state.status="广播已暂停";self.publish(true)}}
 override func broadcastResumed(){CaptureIPC.event(.resumed);client.queue.async{self.state.status="广播已继续";self.publish(true)}}
 override func broadcastFinished(){
  CaptureIPC.event(.stopped)
  // ReplayKit may kill the extension as soon as this callback returns. Persist
  // FIRST, then give finalization a small, bounded opportunity, not a guarantee.
  client.queue.sync{state.status=terminalStatus ?? "结束中，尾句待确认";persist();publish(true)}
  let done=DispatchSemaphore(value:0)
  client.finish(timeout:1.0){[self] finished in
   add(transcript.finishFinals())
   state.status=terminalStatus ?? (finished ? "广播已结束" : "广播已结束，未确认尾句见恢复快照")
   persist();writeSegments();publish(true);done.signal()
  }
  _=done.wait(timeout:.now()+1.2)
 }
}
