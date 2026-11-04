import AVKit
import UIKit
import SwiftUI

@MainActor
final class Picture:NSObject,ObservableObject,AVPictureInPictureSampleBufferPlaybackDelegate,AVPictureInPictureControllerDelegate {
 private(set) var layer=AVSampleBufferDisplayLayer()
 @Published var status="先开启画中画，再开始广播"
 private var controller:AVPictureInPictureController?
 private var timebase:CMTimebase?
 private var timer:Timer?
 private weak var surface:UIView?
 private var hasFrame=false
 private var renderPolicy = PiPRenderPolicy()
 private var policy = PiPPolicy()
 private var startup: Task<Void,Never>?
 private var backgroundObserver: NSObjectProtocol?
 private var lastReadinessLog: Int?
 private var rebuildPending = false
 override init(){
  super.init()
  var tb:CMTimebase?
  CMTimebaseCreateWithSourceClock(allocator:kCFAllocatorDefault,sourceClock:CMClockGetHostTimeClock(),timebaseOut:&tb)
  timebase=tb
  if let tb=tb{CMTimebaseSetTime(tb,time:CMClockGetTime(CMClockGetHostTimeClock()));CMTimebaseSetRate(tb,rate:1);layer.controlTimebase=tb}
  layer.videoGravity = .resizeAspect
  backgroundObserver = NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
   Task { @MainActor [weak self] in
    guard let self else { return }
    self.policy.background()
   }
  }
  timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){[weak self] _ in Task { @MainActor [weak self] in self?.render(CaptureIPC.presentationCaption(existing: Store.read() ?? Caption())) }}
 }
 isolated deinit {
  timer?.invalidate()
  startup?.cancel()
  if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
 }
 private func cancelStartup() {
  policy.cancel(); startup?.cancel(); startup=nil
 }
 func attach(to view:UIView){
  surface=view
  Diagnostics.record("pip.attach.before")
  view.layer.addSublayer(layer)
  layer.frame=view.bounds
  Diagnostics.record(layer.superlayer === view.layer ? "pip.attach.success":"pip.attach.failure")
 }
 func start(){
  Diagnostics.record("pip.start.requested")
  guard AVPictureInPictureController.isPictureInPictureSupported() else{
   status="此设备不支持画中画";Diagnostics.record("pip.unsupported");return
  }
  guard UIApplication.shared.applicationState == .active,
        let surface,surface.window != nil else{
   status="请在 App 前台、字幕预览可见时开启";Diagnostics.record("pip.surface.unavailable");return
  }
  Diagnostics.record("pip.window.attached",code:surface.window == nil ? 0:1)
  surface.layoutIfNeeded()
  layer.frame=surface.bounds
  guard !layer.bounds.isEmpty else{
   status="字幕预览尚未布局，请稍后再点";Diagnostics.record("pip.surface.unavailable");return
  }
  var audioStage="pip.audio.category"
  do{
   Diagnostics.record("pip.audio.category.before")
   try AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback,options:[.mixWithOthers])
   Diagnostics.record("pip.audio.category.success")
   audioStage="pip.audio.active"
   Diagnostics.record("pip.audio.active.before")
   try AVAudioSession.sharedInstance().setActive(true)
   Diagnostics.record("pip.audio.active.success")
  }catch{
   status="音频会话启动失败";Diagnostics.record(audioStage+".failure",code:(error as NSError).code);return
  }
  guard controller?.isPictureInPictureActive != true,
        controller?.isPictureInPictureSuspended != true else { return }
  // A second tap supersedes the old gesture, never stacks another task.
  cancelStartup()
  if controller != nil { controller?.delegate=nil; controller=nil }
  ensureController()
  let token=policy.begin(now:CACurrentMediaTime())
  status="正在准备字幕画面"
  startup=Task { @MainActor [weak self] in
   while !Task.isCancelled {
    guard let self,self.policy.token == token,self.policy.valid else { return }
    self.render(CaptureIPC.presentationCaption(existing: Store.read() ?? Caption()))
    self.ensureController()
    let readiness=(self.layer.isReadyForDisplay ? 1:0) | (self.controller?.isPictureInPicturePossible == true ? 2:0)
    if self.lastReadinessLog != readiness {
     self.lastReadinessLog=readiness
     Diagnostics.record("pip.layer.readyForDisplay",code:self.layer.isReadyForDisplay ? 1:0)
     Diagnostics.record("pip.possible",code:self.controller?.isPictureInPicturePossible == true ? 1:0)
    }
    let action=self.policy.step(now:CACurrentMediaTime(),
     active:UIApplication.shared.applicationState == .active,
     ready:self.hasFrame && self.layer.status != .failed && self.layer.isReadyForDisplay,
     possible:self.controller?.isPictureInPicturePossible == true)
    switch action {
    case .start:
     guard let controller=self.controller else { self.cancelStartup(); return }
     controller.invalidatePlaybackState()
     self.status="正在开启画中画"
     Diagnostics.record("pip.start.before")
     controller.startPictureInPicture()
     Diagnostics.record("pip.start.returned")
    case .retry:
     Diagnostics.record("pip.start.retry")
     // Replacing a silent inactive controller isolates any late callbacks.
     self.controller?.delegate=nil
     self.controller=nil
     self.ensureController()
    case .timeoutReadiness:
     self.status=self.layer.isReadyForDisplay ? "系统暂不可开启画中画，请再点一次" : "字幕首帧准备超时，请再点一次"
     Diagnostics.record("pip.start.timeout.readiness",code:readiness)
     return
    case .timeoutDelegate:
     self.status="画中画未确认开启，请再点一次"
     Diagnostics.record("pip.start.timeout.delegate")
     return
    case .timeoutDidStart:
     self.status="系统尚未确认画中画开启，请稍后检查"
     Diagnostics.record("pip.start.timeout.didStart")
     return
    case .cancelled: return
    case .wait: break
    }
    do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
   }
  }
 }
 private func ensureController() {
  guard controller == nil else { return }
  Diagnostics.record("pip.controller.before")
  let source=AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:layer,playbackDelegate:self)
  controller=AVPictureInPictureController(contentSource:source)
  controller?.delegate=self
  controller?.requiresLinearPlayback=true
  controller?.canStartPictureInPictureAutomaticallyFromInline=false
  Diagnostics.record(controller == nil ? "pip.controller.failure":"pip.controller.success")
 }
 func stop(){
  cancelStartup()
  Diagnostics.record("pip.stop.before")
  controller?.stopPictureInPicture()
  Diagnostics.record("pip.stop.returned")
 }
 private func recoverRenderer() {
  guard layer.status == .failed else { return }
  Diagnostics.record("pip.renderer.failed")
  if let error=layer.error { Diagnostics.recordRendererError(error) }
  hasFrame=false
  // Log the error BEFORE flush removes it. Recreate the sample on this render.
  layer.flushAndRemoveImage()
  Diagnostics.record("pip.renderer.flush")
  let active=controller?.isPictureInPictureActive == true || controller?.isPictureInPictureSuspended == true || policy.acceptDidStart
  switch renderPolicy.failed(active:active) {
  case .flush: break
  case .deferRebuild: rebuildPending=true
  case .rebuild: rebuildLayer()
  }
 }
 private func rebuildLayer() {
  controller?.delegate=nil; controller=nil
  let old=layer
  layer=AVSampleBufferDisplayLayer()
  layer.videoGravity = .resizeAspect
  layer.controlTimebase=timebase
  if let surface {
   layer.frame=surface.bounds
   surface.layer.insertSublayer(layer,above:old)
   (surface as? VideoSurface.Surface)?.display=layer
  }
  old.removeFromSuperlayer()
  hasFrame=false; renderPolicy.rebuilt(); rebuildPending=false
  Diagnostics.record("pip.renderer.rebuild")
 }
 func render(_ caption:Caption){
  recoverRenderer()
  guard layer.status != .failed else { return }
  let width=960,height=320
  var buffer:CVPixelBuffer?
  guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32ARGB,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&buffer)==kCVReturnSuccess,let b=buffer else{return}
  CVPixelBufferLockBaseAddress(b,[])
  guard let context=CGContext(data:CVPixelBufferGetBaseAddress(b),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(b),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue) else{CVPixelBufferUnlockBaseAddress(b,[]);return}
  context.setFillColor(UIColor.black.withAlphaComponent(0.85).cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
  context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
  UIGraphicsPushContext(context)
  let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center;paragraph.lineBreakMode = .byTruncatingHead
  let originalParagraph=paragraph.mutableCopy() as! NSMutableParagraphStyle
  originalParagraph.lineBreakMode = .byTruncatingTail
  let o=caption.original.isEmpty ? "Live Subs" : caption.original
  let t=caption.translated.isEmpty ? caption.status : caption.translated
  (o as NSString).draw(in:CGRect(x:32,y:26,width:896,height:94),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.lightGray,.paragraphStyle:originalParagraph])
  (t as NSString).draw(in:CGRect(x:32,y:128,width:896,height:160),withAttributes:[.font:UIFont.systemFont(ofSize:45,weight:.semibold),.foregroundColor:UIColor.white,.paragraphStyle:paragraph])
  UIGraphicsPopContext();CVPixelBufferUnlockBaseAddress(b,[])
  var description:CMVideoFormatDescription?
  CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:b,formatDescriptionOut:&description)
  guard let desc=description else{return}
  // Both the control timebase and PTS use host media time, never wall-clock epoch.
  let now=timebase.map{CMTimebaseGetTime($0)} ?? CMClockGetTime(CMClockGetHostTimeClock())
  let pts=CMTime(value:renderPolicy.nextTick(hostSeconds:CMTimeGetSeconds(now)),timescale:60000)
  var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:5),presentationTimeStamp:pts,decodeTimeStamp:.invalid)
  var sample:CMSampleBuffer?
  CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:b,formatDescription:desc,sampleTiming:&timing,sampleBufferOut:&sample)
  if let sample=sample{

   if layer.isReadyForMoreMediaData{
    let first = !hasFrame
    if first{
     Diagnostics.record("pip.frame.width",code:width)
     Diagnostics.record("pip.frame.height",code:height)
     Diagnostics.record("pip.frame.subtype",code:Int(CMFormatDescriptionGetMediaSubType(desc)))
     let seconds=CMTimeGetSeconds(timing.presentationTimeStamp)
     if seconds.isFinite,abs(seconds)<1_000_000_000{
      Diagnostics.record("pip.frame.ptsMillis",code:Int(seconds*1000))
     }
     Diagnostics.record("pip.frame.first.before")
    }
    layer.enqueue(sample)
    if first{
     if layer.status == .failed{
      Diagnostics.record("pip.frame.first.failure",code:(layer.error as NSError?)?.code ?? -1)
      if let error=layer.error { Diagnostics.recordRendererError(error) }
     }else{
      hasFrame=true;Diagnostics.record("pip.frame.first.success")
      Diagnostics.record("pip.frame.enqueued.not.proven.presented")
     }
    }
   }
  }
 }
 // AVKit can synchronously query playback on its own queue. Never hop
 // to the main actor or read mutable UI state in these callbacks.
 nonisolated func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,setPlaying playing:Bool){
  Diagnostics.record("pip.delegate.playing.before")
  Diagnostics.record("pip.delegate.playing.success")
 }
 nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController:AVPictureInPictureController)->CMTimeRange{
  Diagnostics.record("pip.delegate.range.before")
  Diagnostics.record("pip.delegate.range.success")
  return CMTimeRange(start:.negativeInfinity,duration:.positiveInfinity)
 }
 nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController:AVPictureInPictureController)->Bool{
  Diagnostics.record("pip.delegate.paused.before")
  Diagnostics.record("pip.delegate.paused.success")
  return false
 }
 nonisolated func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,didTransitionToRenderSize newRenderSize:CMVideoDimensions){
  Diagnostics.record("pip.delegate.size.before")
  Diagnostics.record("pip.delegate.size.success")
 }
 nonisolated func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,skipByInterval skipInterval:CMTime,completion completionHandler:@escaping ()->Void){
  Diagnostics.record("pip.delegate.skip.before")
  completionHandler()
  Diagnostics.record("pip.delegate.skip.success")
 }
 nonisolated func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,failedToStartPictureInPictureWithError error:Error){
  Diagnostics.record("pip.delegate.failedStart.before")
  Diagnostics.record("pip.start.failure",code:(error as NSError).code)
  Diagnostics.record("pip.delegate.failedStart.success")
  let identity=ObjectIdentifier(pictureInPictureController)
  Task { @MainActor [weak self] in
   guard let self, self.controller.map(ObjectIdentifier.init) == identity else { return }
   self.cancelStartup()
   self.status="画中画启动失败，请导出诊断日志"
  }
 }
 nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){
  Diagnostics.record("pip.delegate.willStart.before")
  Diagnostics.record("pip.delegate.willStart.success")
  let receivedAt=CACurrentMediaTime()
  let identity=ObjectIdentifier(pictureInPictureController)
  Task { @MainActor [weak self] in
   guard let self,self.controller.map(ObjectIdentifier.init) == identity else { return }
   self.policy.willStart(now:receivedAt)
  }
 }
 nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){
  Diagnostics.record("pip.delegate.didStart.before")
  Diagnostics.record("pip.delegate.didStart.success")
  let identity=ObjectIdentifier(pictureInPictureController)
  Task { @MainActor [weak self] in
   guard let self,self.controller.map(ObjectIdentifier.init) == identity else { return }
   // Background/timeout does not revoke an already-issued user-authorized start.
   let result=self.policy.didStart()
   guard result != .rejected else { self.controller?.stopPictureInPicture(); return }
   if result == .late { Diagnostics.record("pip.start.didStart.late") }
   self.startup?.cancel(); self.startup=nil
   self.status="画中画已开启"
   Diagnostics.record("pip.start.success")
  }
 }
 nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){
  let identity=ObjectIdentifier(pictureInPictureController)
  Task { @MainActor [weak self] in
   guard let self,self.controller.map(ObjectIdentifier.init) == identity else { return }
   self.cancelStartup()
  }
 }
 nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){
  Diagnostics.record("pip.delegate.didStop.before")
  Diagnostics.record("pip.delegate.didStop.success")
  let identity=ObjectIdentifier(pictureInPictureController)
  Task { @MainActor [weak self] in
   guard let self,self.controller.map(ObjectIdentifier.init) == identity else { return }
   self.cancelStartup()
   self.status="画中画已关闭"
   if self.rebuildPending { self.rebuildLayer() }
  }
 }

}
struct VideoSurface:UIViewRepresentable{
 let picture:Picture
 func makeUIView(context:Context)->UIView{let v=Surface();v.display=picture.layer;picture.attach(to:v);return v}
 func updateUIView(_ uiView:UIView,context:Context){}
 final class Surface:UIView{var display:AVSampleBufferDisplayLayer?;override func layoutSubviews(){super.layoutSubviews();display?.frame=bounds}}
}
