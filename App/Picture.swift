import AVKit
import UIKit
import SwiftUI

@MainActor
final class Picture:NSObject,ObservableObject,AVPictureInPictureSampleBufferPlaybackDelegate,AVPictureInPictureControllerDelegate {
 let layer=AVSampleBufferDisplayLayer()
 @Published var status="先开启画中画，再开始广播"
 private var controller:AVPictureInPictureController?
 private var timebase:CMTimebase?
 private var timer:Timer?
 private weak var surface:UIView?
 private var hasFrame=false
 override init(){
  super.init()
  var tb:CMTimebase?
  CMTimebaseCreateWithSourceClock(allocator:kCFAllocatorDefault,sourceClock:CMClockGetHostTimeClock(),timebaseOut:&tb)
  timebase=tb
  if let tb=tb{CMTimebaseSetTime(tb,time:.zero);CMTimebaseSetRate(tb,rate:1);layer.controlTimebase=tb}
  layer.videoGravity = .resizeAspect
  timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){[weak self] _ in Task { @MainActor [weak self] in self?.render(Store.read() ?? Caption()) }}
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
  render(Store.read() ?? Caption())
  guard hasFrame,layer.status != .failed else{
   status="字幕画面尚未就绪，请稍后再点";Diagnostics.record("pip.frame.unavailable");return
  }
  if controller == nil{
   Diagnostics.record("pip.controller.before")
   let source=AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:layer,playbackDelegate:self)
   controller=AVPictureInPictureController(contentSource:source)
   controller?.delegate=self
   controller?.requiresLinearPlayback=true
   Diagnostics.record(controller == nil ? "pip.controller.failure":"pip.controller.success")
  }
  guard let controller else{
   status="无法创建画中画";Diagnostics.record("pip.controller.unavailable");return
  }
  guard !controller.isPictureInPictureActive,!controller.isPictureInPictureSuspended else{
   status="画中画已开启或正在切换";return
  }
  controller.invalidatePlaybackState()
  guard controller.isPictureInPicturePossible else{
   status="画中画尚未就绪，请稍后再点";Diagnostics.record("pip.not.ready");return
  }
  status="正在开启画中画"
  Diagnostics.record("pip.start.before")
  controller.startPictureInPicture()
  // Call returned; actual activation is recorded by didStart.
  Diagnostics.record("pip.start.success")
 }
 func stop(){
  Diagnostics.record("pip.stop.before")
  controller?.stopPictureInPicture()
  Diagnostics.record("pip.stop.success")
 }
 func render(_ caption:Caption){
  let width=960,height=320
  var buffer:CVPixelBuffer?
  guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32ARGB,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&buffer)==kCVReturnSuccess,let b=buffer else{return}
  CVPixelBufferLockBaseAddress(b,[])
  guard let context=CGContext(data:CVPixelBufferGetBaseAddress(b),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(b),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue) else{CVPixelBufferUnlockBaseAddress(b,[]);return}
  context.setFillColor(UIColor.black.withAlphaComponent(0.85).cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
  context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
  UIGraphicsPushContext(context)
  let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center;paragraph.lineBreakMode = .byTruncatingHead
  let o=caption.original.isEmpty ? "Live Subs" : caption.original
  let t=caption.translated.isEmpty ? caption.status : caption.translated
  (o as NSString).draw(in:CGRect(x:32,y:26,width:896,height:94),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.lightGray,.paragraphStyle:paragraph])
  (t as NSString).draw(in:CGRect(x:32,y:128,width:896,height:160),withAttributes:[.font:UIFont.systemFont(ofSize:45,weight:.semibold),.foregroundColor:UIColor.white,.paragraphStyle:paragraph])
  UIGraphicsPopContext();CVPixelBufferUnlockBaseAddress(b,[])
  var description:CMVideoFormatDescription?
  CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:b,formatDescriptionOut:&description)
  guard let desc=description else{return}
  var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:5),presentationTimeStamp:timebase.map{CMTimebaseGetTime($0)} ?? .zero,decodeTimeStamp:.invalid)
  var sample:CMSampleBuffer?
  CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:b,formatDescription:desc,sampleTiming:&timing,sampleBufferOut:&sample)
  if let sample=sample{
   if layer.status == .failed{layer.flush();hasFrame=false;Diagnostics.record("pip.renderer.failed")}
   if layer.isReadyForMoreMediaData{
    let first = !hasFrame
    if first{Diagnostics.record("pip.frame.first.before")}
    layer.enqueue(sample)
    if first{
     if layer.status == .failed{
      Diagnostics.record("pip.frame.first.failure",code:(layer.error as NSError?)?.code ?? -1)
     }else{
      hasFrame=true;Diagnostics.record("pip.frame.first.success")
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
  Task { @MainActor [weak self] in self?.status="画中画启动失败，请导出诊断日志" }
 }
 nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){
  Diagnostics.record("pip.delegate.willStart.before")
  Diagnostics.record("pip.delegate.willStart.success")
 }
 nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){
  Diagnostics.record("pip.delegate.didStart.before")
  Diagnostics.record("pip.delegate.didStart.success")
  Task { @MainActor [weak self] in self?.status="画中画已开启" }
 }
 nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){
  Diagnostics.record("pip.delegate.didStop.before")
  Diagnostics.record("pip.delegate.didStop.success")
  Task { @MainActor [weak self] in self?.status="画中画已关闭" }
 }

}
struct VideoSurface:UIViewRepresentable{
 let picture:Picture
 func makeUIView(context:Context)->UIView{let v=Surface();v.display=picture.layer;picture.attach(to:v);return v}
 func updateUIView(_ uiView:UIView,context:Context){}
 final class Surface:UIView{var display:AVSampleBufferDisplayLayer?;override func layoutSubviews(){super.layoutSubviews();display?.frame=bounds}}
}
