import Foundation

// Mutable socket state is confined to queue; callbacks are configured before start.
final class Soniox: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
 let queue=DispatchQueue(label:"soniox.serial")
 private var ws:URLSessionWebSocketTask?
 private var session:URLSession?
 private var timer:DispatchSourceTimer?
 private var generation=0
 private var active=false
 private var ready=false
 private var authenticated=false
 private var ending=false
 private var endCompletion:(@Sendable (Bool)->Void)?
 private var pending=0
 private var attempt=0
 private var lastReceive=Date()
 private var lastVoice=Date.distantPast
 private var key=""
 private var config=""
 var onEvent:(@Sendable (CaptureEvent, Int?, String?)->Void)?
 var onMessage:(@Sendable ([String:Any])->Void)?
 var onStatus:(@Sendable (String)->Void)?
 var onFatal:(@Sendable (String)->Void)?
 var onReconnect:(@Sendable ()->Void)?
 /// `config` is the start request JSON from SonioxConfig (it never contains the key).
 func start(_ key:String,config:String){queue.async{self.key=key;self.config=config;self.attempt=0;self.ending=false;self.active=true;self.connect()}}
 func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
  queue.async { [self] in
   guard active, ws === webSocketTask else { return }
   onEvent?(.transportOpen,nil,nil)
  }
 }
 private func transportError(_ error: Error?) {
  guard let error = error else { return }
  let e=error as NSError
  let domain = [NSURLErrorDomain,NSPOSIXErrorDomain].contains(e.domain) ? e.domain : "Other"
  onEvent?(.transportError,e.code,domain)
 }
 private func connect(){
  guard active else{return}
  onEvent?(.connecting,nil,nil)
  generation+=1;let g=generation;ready=false;authenticated=false;pending=0
  var r=URLRequest(url:URL(string:"wss://stt-rt.soniox.com/transcribe-websocket")!)
  r.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
  let sessionConfig=URLSessionConfiguration.ephemeral;sessionConfig.timeoutIntervalForRequest=120
  session=URLSession(configuration:sessionConfig,delegate:self,delegateQueue:nil)
  let socket=session!.webSocketTask(with:r);socket.maximumMessageSize=262_144;ws=socket;socket.resume()
  socket.send(.string(self.config)){err in self.queue.async{
   guard g==self.generation else{return}
   if let err = err {self.transportError(err);self.retry();return}
   self.ready=true;self.lastReceive=Date();self.onEvent?(.configSent,nil,nil);self.onStatus?("连接已建立，认证待有效响应确认");self.receive(g)
  }}
  timer?.cancel();let t=DispatchSource.makeTimerSource(queue:queue)
  t.schedule(deadline:.now()+5,repeating:5)
  t.setEventHandler{[weak self] in
   guard let self=self,self.ready else{return}
   self.ws?.send(.string("{\"type\":\"keepalive\"}")){_ in}
   self.ws?.sendPing{err in if err != nil {self.queue.async{if g==self.generation{self.transportError(err);self.retry()}}}}
   if Date().timeIntervalSince(self.lastReceive)>35 && Date().timeIntervalSince(self.lastVoice)<10 {self.retry()}
  };timer=t;t.resume()
 }
 func send(_ data:Data,voiced:Bool){queue.async{
  if voiced{self.lastVoice=Date()}
  guard self.ready,!self.ending,self.pending+data.count<=96000 else{return}
  self.pending+=data.count;let g=self.generation
  self.ws?.send(.data(data)){err in self.queue.async{
   guard g==self.generation else{return}
   self.pending=max(0,self.pending-data.count);if let err = err{self.transportError(err);self.retry()}
  }}
 }}
 private func receive(_ g:Int){ws?.receive{result in self.queue.async{
  guard g==self.generation,self.active else{return}
  switch result {
  case .failure(let error):self.transportError(error);self.retry()
  case .success(let message):
   let data:Data
   switch message{case .string(let s):data=Data(s.utf8);case .data(let d):data=d;@unknown default:return}
   if let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{
    self.lastReceive=Date()
    if let code=obj["error_code"] as? Int{
     self.onEvent?(.protocolError,code,"Soniox")
     if SonioxRetry.isFatal(code){self.fail("Soniox 错误 \(code)");return}
     self.retry(code:code);return
    }
    // Only a valid non-error protocol response proves a healthy connection.
    if obj["tokens"] is [[String:Any]] || obj["finished"] as? Bool == true {
     if !self.authenticated { self.authenticated=true;self.onEvent?(.protocolConfirmed,nil,nil) }
     let tokens=obj["tokens"] as? [[String:Any]] ?? []
     let translated=tokens.filter { $0["translation_status"] as? String == "translation" }.count
     let markers=tokens.filter { ($0["text"] as? String).map { $0 == "<end>" || $0 == "<fin>" } ?? true }.count
     self.attempt=0
    }
    self.onMessage?(obj)
    if obj["finished"] as? Bool == true{
     self.onEvent?(.serverFinished,nil,nil)
     if self.ending { self.completeEnd(true) } else { self.stopInternal();self.onStatus?("服务端已结束会话") };return
    }
   };self.receive(g)
  }
 }}}
 private func retry(code:Int?=nil){
  guard active else{return}
  let status=code ?? (ws?.response as? HTTPURLResponse)?.statusCode
  if let status=status,SonioxRetry.isFatal(status){
   onEvent?(.protocolError,status,"Soniox");fail("Soniox 错误 \(status)");return}
  if ending {completeEnd(false);return}
  guard attempt<SonioxRetry.maximumRetries else{fail("无法连接 Soniox，已达到重试上限");return}
  generation+=1;let g=generation;ready=false
  ws?.cancel(with:.goingAway,reason:nil);session?.invalidateAndCancel();timer?.cancel();timer=nil
  onEvent?(.retrying,status,nil)
  attempt+=1
  let delay=SonioxRetry.delay(attempt:attempt,rateLimited:status==429)
  onReconnect?();onStatus?("断线，\(Int(delay)) 秒后重连（\(attempt)/\(SonioxRetry.maximumRetries)）")
  queue.asyncAfter(deadline:.now()+delay){if self.active && g==self.generation{self.connect()}}
 }
 private func fail(_ message:String){
  let callback=endCompletion;endCompletion=nil;ending=false
  stopInternal()
  onFatal?(message)
  callback?(false)
 }
 private func stopInternal(){active=false;ready=false;generation+=1;timer?.cancel();timer=nil;ws?.cancel(with:.normalClosure,reason:nil);session?.invalidateAndCancel()}
 // Called from any queue; all messages and completion run on queue.
 // Empty TEXT (not empty binary) ends audio and requests final results.
 func finish(timeout:TimeInterval=1.5,completion:@escaping @Sendable (Bool)->Void){queue.async{
  guard !self.ending else {completion(false);return}
  guard self.active,self.ready else {self.stopInternal();completion(false);return}
  self.ending=true;self.endCompletion=completion;self.timer?.cancel();self.timer=nil
  let g=self.generation
  self.ws?.send(.string("")){error in self.queue.async{
   if g==self.generation,error != nil {self.completeEnd(false)}
  }}
  self.queue.asyncAfter(deadline:.now()+max(0.1,timeout)){
   if g==self.generation,self.ending {self.completeEnd(false)}
  }
 }}
 private func completeEnd(_ receivedFinished:Bool){
  let callback=endCompletion;endCompletion=nil;ending=false
  stopInternal();callback?(receivedFinished)
 }
 func stop(){queue.async{
  if self.ending {self.completeEnd(false)}else{self.stopInternal()}
 }}
}
