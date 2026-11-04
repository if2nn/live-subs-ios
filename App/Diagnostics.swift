import Foundation

/// Fixed events only. Synchronous write + FileHandle.synchronize before return.
/// Best effort on filesystem failures; never a crash interception guarantee.
public enum Diagnostics {
 private static let storage=EventStorage()
 public static func install(){
  _ = storage.beginSession()
  NSSetUncaughtExceptionHandler { exception in
   switch exception.name.rawValue {
   case "NSInvalidArgumentException": Diagnostics.record("exception.NSInvalidArgumentException")
   case "NSInternalInconsistencyException": Diagnostics.record("exception.NSInternalInconsistencyException")
   case "NSRangeException": Diagnostics.record("exception.NSRangeException")
   default: Diagnostics.record("exception.other")
   }
  }
  record("app.launch")
 }
 public static func record(_ event:String){storage.record(event,code:nil)}
 public static func record(_ event:String,code:Int){storage.record(event,code:code)}
 public static func recordRendererError(_ error:Error){
  let e=error as NSError
  // Never persist raw descriptions, userInfo or nested server echoes.
  let domain:String
  switch e.domain {
  case "AVFoundationErrorDomain": domain="AVFoundationErrorDomain"
  case "CoreMediaErrorDomain": domain="CoreMediaErrorDomain"
  case "NSOSStatusErrorDomain": domain="NSOSStatusErrorDomain"
  case "NSCocoaErrorDomain": domain="NSCocoaErrorDomain"
  default: domain="other"
  }
  storage.recordSafeError(domain:domain,code:e.code)
 }
 public static var previousSessionSummary:String{storage.summary}
 public static var exportURL:URL?{storage.export()}
}

private final class EventStorage:@unchecked Sendable {
 private let lock=NSRecursiveLock()
 private var installed=false
 private var previous="暂无上次会话记录"
 private let maximum=128*1024
 private let retained=64*1024
 private let operations:Set<String>=[
  "pip.attach","pip.audio.category","pip.audio.active","pip.controller",
  "pip.frame.first","pip.start","pip.stop","pip.delegate.playing",
  "pip.delegate.range","pip.delegate.paused","pip.delegate.size",
  "pip.delegate.skip","pip.delegate.willStart","pip.delegate.didStart",
  "pip.delegate.didStop","pip.delegate.failedStart"
 ]
 private let simple:Set<String>=[
  "pip.possible","pip.start.returned","pip.stop.returned","pip.start.retry",
  "pip.start.timeout.readiness","pip.start.timeout.delegate","pip.start.timeout.didStart","pip.start.didStart.late","pip.renderer.flush","pip.renderer.rebuild",
  "app.launch","pip.start.requested","pip.unsupported","pip.surface.unavailable",
  "pip.frame.unavailable","pip.controller.unavailable","pip.not.ready",
  "pip.layer.status","pip.layer.ready","pip.layer.readyForDisplay","pip.layer.error","pip.window.attached",
  "pip.frame.ptsMillis","pip.frame.width","pip.frame.height","pip.frame.subtype",
  "pip.frame.enqueued.not.proven.presented",
  "pip.renderer.failed","exception.NSInvalidArgumentException",
  "exception.NSInternalInconsistencyException","exception.NSRangeException","exception.other"
 ]
 private func allowed(_ event:String)->Bool{
  if simple.contains(event){return true}
  guard let dot=event.lastIndex(of:".") else{return false}
  return operations.contains(String(event[..<dot])) &&
   ["before","success","failure"].contains(String(event[event.index(after:dot)...]))
 }
 func recordSafeError(domain:String,code:Int){
  lock.lock();defer{lock.unlock()}
  if !installed{_ = beginSession()}
  guard installed,let dir=directory() else{return}
  let description:String
  switch (domain,code) {
  case ("AVFoundationErrorDomain",-11800): description="AVFoundation unknown failure"
  case ("AVFoundationErrorDomain",-11819): description="Media services reset"
  case ("AVFoundationErrorDomain",-11847): description="Operation interrupted"
  default: description="Renderer failure; original description redacted"
  }
  let line="\(Date().timeIntervalSince1970) pip.renderer.error domain=\(domain) code=\(code) description=\(description)\n"
  let url=dir.appendingPathComponent("diagnostics.log")
  do{
   var data=try bounded(url)
   if data.count>retained{data=Data(data.suffix(retained))}
   data.append(Data(line.utf8));try durableWrite(data,to:url)
  }catch{}
 }
 private func directory()->URL?{
  let fm=FileManager.default
  guard let url=fm.urls(for:.documentDirectory,in:.userDomainMask).first else{return nil}
  do{try fm.createDirectory(at:url,withIntermediateDirectories:true);return url}catch{return nil}
 }
 private func bounded(_ url:URL)throws->Data{
  guard FileManager.default.fileExists(atPath:url.path) else{return Data()}
  let h=try FileHandle(forReadingFrom:url);defer{try? h.close()}
  let size=try h.seekToEnd()
  try h.seek(toOffset:size>UInt64(maximum) ? size-UInt64(maximum):0)
  return try h.readToEnd() ?? Data()
 }
 private func durableWrite(_ data:Data,to url:URL)throws{
  try data.write(to:url,options:.atomic)
  let h=try FileHandle(forWritingTo:url);defer{try? h.close()}
  try h.synchronize()
 }
 func beginSession()->Bool{
  lock.lock();defer{lock.unlock()}
  guard !installed else{return false}
  // Snapshot old final event before creating/truncating the current session.
  guard let dir=directory() else{return false}
  let current=dir.appendingPathComponent("diagnostics.log")
  let old=dir.appendingPathComponent("previous-session.log")
  do{
   let data=try bounded(current)
   if !data.isEmpty{try durableWrite(data,to:old)}
   let previousData=try bounded(old)
   if let text=String(data:previousData,encoding:.utf8),
      let last=text.split(separator:"\n").last{
    previous="上次会话最后记录 "+String(last)
   }
   try durableWrite(Data(),to:current)
   installed=true
   return true
  }catch{return false}
 }
 var summary:String{
  lock.lock();defer{lock.unlock()}
  return previous
 }
 func record(_ event:String,code:Int?){
  guard allowed(event) else{return}
  lock.lock();defer{lock.unlock()}
  if !installed{_ = beginSession()}
  guard installed,let dir=directory() else{return}
  let url=dir.appendingPathComponent("diagnostics.log")
  let suffix=code.map{" code="+String($0)} ?? ""
  guard let bytes="\(Date().timeIntervalSince1970) \(event)\(suffix)\n".data(using:.utf8) else{return}
  do{
   let size=(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.intValue ?? 0
   if size+bytes.count>maximum{
    var tail=Data(try bounded(url).suffix(retained))
    if let newline=tail.firstIndex(of:10){tail=Data(tail.suffix(from:tail.index(after:newline)))}
    tail.append(bytes)
    try durableWrite(tail,to:url)
   }else{
    let h=try FileHandle(forWritingTo:url);defer{try? h.close()}
    try h.seekToEnd()
    try h.write(contentsOf:bytes)
    try h.synchronize()
   }
  }catch{
   // No raw error text, no recursion, no signal handler.
  }
 }
 func export()->URL?{
  lock.lock();defer{lock.unlock()}
  guard let dir=directory() else{return nil}
  do{
   var data=Data("PREVIOUS SESSION\n".utf8)
   data.append(try bounded(dir.appendingPathComponent("previous-session.log")))
   data.append(Data("\nCURRENT SESSION\n".utf8))
   data.append(try bounded(dir.appendingPathComponent("diagnostics.log")))
   data.append(Data("\nEXTENSION RUNTIME DIAGNOSTICS\n".utf8))
   data.append(Data(CaptureIPC.diagnosticText.utf8))
   data.append(Data("\nEXTENSION BOUNDED EVENTS\n".utf8))
   data.append(Data(CaptureIPC.exportLogText.utf8))
   let url=dir.appendingPathComponent("diagnostics-export.log")
   try durableWrite(data,to:url)
   return url
  }catch{return nil}
 }
}
