import AVKit
import UIKit
import SwiftUI

@MainActor
final class Picture:NSObject,ObservableObject,@preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate,@preconcurrency AVPictureInPictureControllerDelegate {
 let layer=AVSampleBufferDisplayLayer()
 @Published var status="先开启画中画，再开始广播"
 private var controller:AVPictureInPictureController?
 private var timebase:CMTimebase?
 private var timer:Timer?
 private var observation:NSKeyValueObservation?
 override init(){
  super.init()
  var tb:CMTimebase?
  CMTimebaseCreateWithSourceClock(allocator:kCFAllocatorDefault,sourceClock:CMClockGetHostTimeClock(),timebaseOut:&tb)
  timebase=tb
  if let tb=tb{CMTimebaseSetTime(tb,time:.zero);CMTimebaseSetRate(tb,rate:1);layer.controlTimebase=tb}
  layer.videoGravity = .resizeAspect
  if AVPictureInPictureController.isPictureInPictureSupported(){
   let source=AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:layer,playbackDelegate:self)
   controller=AVPictureInPictureController(contentSource:source);controller?.delegate=self
   controller?.requiresLinearPlayback=true
  }else{status="此设备不支持画中画"}
  timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){[weak self] _ in Task { @MainActor [weak self] in self?.render(Store.read() ?? Caption()) }}
 }
 func start(){
  do{
   try AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback,options:[.mixWithOthers])
   try AVAudioSession.sharedInstance().setActive(true)
   render(Store.read() ?? Caption())
   guard let c=controller,c.isPictureInPicturePossible else{status="画中画尚未就绪，请稍后再点";return}
   c.startPictureInPicture()
  }catch{status="音频会话失败"}
 }
 func stop(){controller?.stopPictureInPicture()}
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
   if layer.status == .failed{layer.flush()}
   if layer.isReadyForMoreMediaData{layer.enqueue(sample)}
  }
 }
 func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,setPlaying playing:Bool){}
 func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController:AVPictureInPictureController)->CMTimeRange{CMTimeRange(start:.negativeInfinity,duration:.positiveInfinity)}
 func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController:AVPictureInPictureController)->Bool{false}
 func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,didTransitionToRenderSize newRenderSize:CMVideoDimensions){}
 func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,skipByInterval skipInterval:CMTime,completion completionHandler:@escaping ()->Void){completionHandler()}
 func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,failedToStartPictureInPictureWithError error:Error){status="画中画启动失败 "+error.localizedDescription}
 func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){status="画中画已开启"}
}
struct VideoSurface:UIViewRepresentable{
 let picture:Picture
 func makeUIView(context:Context)->UIView{let v=Surface();v.display=picture.layer;v.layer.addSublayer(picture.layer);return v}
 func updateUIView(_ uiView:UIView,context:Context){}
 final class Surface:UIView{var display:AVSampleBufferDisplayLayer?;override func layoutSubviews(){super.layoutSubviews();display?.frame=bounds}}
}
