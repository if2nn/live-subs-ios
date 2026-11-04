import Foundation
@main struct CaptureStateTests {
 static func main() throws {
  let now=Date(timeIntervalSince1970:10_000)
  func status(_ snapshot:CaptureSnapshot?, shared:Bool=true)->String {
   CaptureState.status(snapshot,now:now,sharedAvailable:shared)
  }
  precondition(status(nil).contains("未收到扩展心跳，无法区分未启动、崩溃或无共享权限"))
  precondition(status(nil,shared:false).contains("共享容器不可用"))
  var s=CaptureSnapshot();s.heartbeat=now;s.lifecycle="started";s.transport="configured"
  precondition(status(s).contains("等待 App 音频"))
  precondition(status(s).contains("待确认")) // config send != authentication
  s.heartbeat=now.addingTimeInterval(-11)
  precondition(status(s).contains("尚未确认停止"))
  precondition(!status(s).contains("广播已停止"))
  s.lifecycle="stopped"
  precondition(status(s).contains("广播已停止")) // only explicit terminal callback
  s.lifecycle="started";s.heartbeat=now;s.keySuccess=false;s.keyOSStatus = -34018
  precondition(status(s).contains("Key 读取失败"))
  s.keySuccess=true;s.authentication="failure"
  precondition(status(s).contains("认证失败"))
  s.authentication="pending";s.transport="error"
  precondition(status(s).contains("网络连接错误"))
  s.transport="configured";s.audioAppBuffers=10;s.audioAppFrames=0
  precondition(status(s).contains("等待 App 音频")) // buffers do not imply PCM frames
  s.audioAppFrames=100;s.lastAudio=now
  precondition(status(s).contains("尚未送出")) // frames delivered but nothing reached Soniox
  s.conversionErrors=3;s.audioFormat="44100Hz 2ch 16bit int BE interleaved"
  precondition(status(s).contains("无法转换") && status(s).contains("BE"))
  s.conversionErrors=0;s.audioSentBytes=32000;s.audioSentChunks=10
  precondition(status(s).contains("已收到音频"))
  precondition(s.sourceTokens == 0 && s.translationTokens == 0) // no token/audio inference
  s.authentication="confirmed"
  precondition(status(s).contains("静音")) // level never above -60 dBFS
  s.audioMaxPeakDB = -20
  precondition(status(s).contains("Soniox 尚未确认处理"))
  s.serverTotalAudioMS=4000
  precondition(status(s).contains("有声音，等待识别"))
  s.sourceTokens=2
  precondition(status(s) == "正在识别与翻译")
  precondition(s.translationTokens == 0)
  s.translationTokens=3;s.lastAudio=now.addingTimeInterval(-9)
  precondition(status(s).contains("近期未收到 App 音频"))
  s.lifecycle="paused"
  precondition(status(s).contains("广播已暂停"))
  s.lifecycle="failed";s.transport="configured"
  precondition(status(s).contains("扩展报告错误"))
  s.lifecycle="started";s.transport="closed"
  precondition(status(s).contains("尚未报告停止"))
  let data=try JSONEncoder().encode(s)
  let roundtrip=try JSONDecoder().decode(CaptureSnapshot.self,from:data)
  precondition(roundtrip.audioAppFrames==100 && roundtrip.sourceTokens==2 && roundtrip.translationTokens==3)
  precondition(roundtrip.relativePath=="Capture/state.json" && roundtrip.schema==2)
  precondition(roundtrip.audioSentBytes==32000 && roundtrip.serverTotalAudioMS==4000 && roundtrip.audioFormat?.contains("BE")==true)
  precondition(data.count < 4096)
  let lost=CaptureState.presentation(snapshot:nil,original:"source",translated:"译文",updated:now,now:now)
  precondition(lost.original.contains("未收到扩展心跳"))
  precondition(lost.original.contains("source") && lost.translated=="译文")
  let repeated=CaptureState.presentation(snapshot:nil,original:lost.original,translated:lost.translated,updated:now,now:now)
  precondition(repeated.original==lost.original)
  let old=CaptureState.presentation(snapshot:s,original:"old",translated:"旧译文",updated:now.addingTimeInterval(-20),now:now)
  precondition(old.original.contains("旧字幕") && old.status.contains("保留上次字幕") && old.translated=="旧译文")
  s.transport="configured";s.lastAudio=now;s.lifecycle="started"
  let fresh=CaptureState.presentation(snapshot:s,original:"fresh",translated:"新译文",updated:now,now:now)
  precondition(fresh.original=="fresh" && fresh.translated=="新译文")
  s.authentication="failure"
  let failed=CaptureState.presentation(snapshot:s,original:"previous",translated:"旧",updated:now,now:now)
  precondition(failed.original.contains("认证失败") && failed.translated=="旧")
  print("CaptureState behavior tests PASS (schema 2 audio-path states); no device/broadcast claims")
 }
}
