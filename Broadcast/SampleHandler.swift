import ReplayKit
import AVFoundation

final class SampleHandler:RPBroadcastSampleHandler{
 private let client=Soniox()
 private var converter:AVAudioConverter?
 private var inputFormat:AVAudioFormat?
 private let outputFormat=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
 private var transcript=Transcript()
 private var state=Caption()
 private var archive:URL?
 private var index=0
 private var recoveryURL:URL?
 private var unarchived:[Segment]=[]
 private var offset=0
 private var began=Date()
 private var lastWrite=Date.distantPast
 override func broadcastStarted(withSetupInfo setupInfo:[String:NSObject]?){
  began=Date()
  guard let root=Store.root else{finishBroadcastWithError(NSError(domain:"App Group 不可用",code:1));return}
  let key=Store.key()
  guard !key.isEmpty else{finishBroadcastWithError(NSError(domain:"请先保存 API Key，检查共享钥匙串签名",code:2));return}
  let dir=root.appendingPathComponent("Sessions")
  try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  let f=DateFormatter();f.timeZone=TimeZone(identifier:"Asia/Shanghai");f.dateFormat="yyyy-MM-dd_HH-mm-ss"
  archive=dir.appendingPathComponent(f.string(from:began)+"_"+UUID().uuidString.prefix(6)+".srt")
  FileManager.default.createFile(atPath:archive!.path,contents:nil,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
  recoveryURL=archive?.deletingPathExtension().appendingPathExtension("recovery.json")
  client.onMessage={[weak self] obj in
   guard let self=self else{return}
   let tokens=obj["tokens"] as? [[String:Any]]
   let arrival=max(0,Int(Date().timeIntervalSince(self.began)*1000)-self.offset)
   if let tokens=tokens,!tokens.isEmpty {self.add(self.transcript.ingest(tokens,arrivalMS:arrival))}
   self.state=self.transcript.caption
   self.persist()
   self.writeSegments()
   self.publish(true)
  }
  client.onStatus={[weak self] s in self?.state.status=s;self?.persist();self?.publish(true)}
  client.onReconnect={[weak self] in
   guard let self=self else{return}
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
  autoreleasepool{convert(sampleBuffer)}
 }
 private func convert(_ sample:CMSampleBuffer){
  guard let desc=CMSampleBufferGetFormatDescription(sample) else{return}
  let format=AVAudioFormat(cmAudioFormatDescription:desc)
  let frames=CMSampleBufferGetNumSamples(sample)
  guard frames>0,let input=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)) else{return}
  input.frameLength=AVAudioFrameCount(frames)
  guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,at:0,frameCount:Int32(frames),into:input.mutableAudioBufferList)==noErr else{return}
  if inputFormat != format{converter=AVAudioConverter(from:format,to:outputFormat);inputFormat=format}
  guard let converter=converter,let output=AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:AVAudioFrameCount(Double(frames)*16000/format.sampleRate+32)) else{return}
  var supplied=false;var error:NSError?
  converter.convert(to:output,error:&error){_,flag in
   if supplied{flag.pointee = .noDataNow;return nil}
   supplied=true;flag.pointee = .haveData;return input
  }
  guard error==nil,let p=output.int16ChannelData?[0],output.frameLength>0 else{return}
  let n=Int(output.frameLength);var peak:Int32=0
  for i in 0..<n{peak=max(peak,abs(Int32(p[i])))}
  client.send(Data(bytes:p,count:n*2),voiced:peak>300)
 }
 override func broadcastPaused(){client.queue.async{self.state.status="广播已暂停";self.publish(true)}}
 override func broadcastResumed(){client.queue.async{self.state.status="广播已继续";self.publish(true)}}
 override func broadcastFinished(){
  // ReplayKit may kill the extension as soon as this callback returns. Persist
  // FIRST, then give finalization a small, bounded opportunity, not a guarantee.
  client.queue.sync{state.status="结束中，尾句待确认";persist();publish(true)}
  let done=DispatchSemaphore(value:0)
  client.finish(timeout:1.0){[self] finished in
   add(transcript.finishFinals())
   state.status=finished ? "广播已结束" : "广播已结束，未确认尾句见恢复快照"
   persist();writeSegments();publish(true);done.signal()
  }
  _=done.wait(timeout:.now()+1.2)
 }
}
