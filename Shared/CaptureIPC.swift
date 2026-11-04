import Foundation
import Darwin

// No App target dependency. Only fixed events and numeric counters are persisted.
// The lock covers timer, ReplayKit callbacks and Soniox's independent serial queue.
enum CaptureIPC {
 static let relativePath = "Capture/state.json"
 static let logRelativePath = "Capture/events.json"
 static let maximumBytes = 65_536
 private static let recorder = CaptureRecorder()

 // Must be first in broadcastStarted, before signing discovery or Soniox/AV setup.
 static func extensionEntered() { recorder.begin() }
 static func extensionDiscovered() { recorder.discover() }
 static func event(_ event: CaptureEvent, code: Int? = nil, domain: String? = nil) {
  recorder.event(event, code: code, domain: domain)
 }
 static func keyRead(success: Bool, status: Int32) { recorder.keyRead(success, status) }
 static func audio(frames: Int) { recorder.audio(frames) }
 static func tokens(source: Int, translation: Int) { recorder.tokens(source, translation) }

 private static func safeIdentifier(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 256 &&
   value.range(of:"^[A-Za-z0-9][A-Za-z0-9.-]*$",options:.regularExpression) != nil
 }
 static func read() -> CaptureSnapshot? {
  guard let root = Store.root else { return nil }
  return read(root: root)
 }
 static func read(root: URL) -> CaptureSnapshot? {
  let url = root.appendingPathComponent(relativePath)
  guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size > 0, size <= maximumBytes,
        let data = try? Data(contentsOf: url, options: .mappedIfSafe),
        data.count <= maximumBytes,
        let value = try? JSONDecoder().decode(CaptureSnapshot.self, from: data),
        value.schema == 1, value.relativePath == relativePath,
        UUID(uuidString:value.session) != nil, safeIdentifier(value.bundleID),
        value.group.map { safeIdentifier($0) } ?? true,
        value.errorDomain.map { ["NSURLErrorDomain","NSPOSIXErrorDomain","Soniox","LiveSubs","OSStatus","Other"].contains($0) } ?? true,
        ["starting","started","paused","stopped","failed"].contains(value.lifecycle),
        ["idle","connecting","open","configured","error","closed"].contains(value.transport),
        ["pending","confirmed","failure"].contains(value.authentication),
        value.heartbeat.timeIntervalSinceNow < 60 else { return nil }
  return value
 }
 static func status(_ s: CaptureSnapshot?, now: Date = Date(), sharedAvailable: Bool = true) -> String {
  CaptureState.status(s,now:now,sharedAvailable:sharedAvailable)
 }
 static func presentationCaption(existing: Caption) -> Caption {
  let rendered = CaptureState.presentation(snapshot:read(), original:existing.original,
   translated:existing.translated, updated:existing.updated, sharedAvailable:Store.root != nil)
  var result=existing
  result.original=rendered.original
  result.translated=rendered.translated
  result.status=rendered.status
  // Deliberately leave updated unchanged. Presentation is not new recognition.
  return result
 }
 static var diagnosticText: String {
  let shared = Store.root != nil
  var lines = ["Main IPC relative path: " + relativePath,
   "Main shared container available: \(shared)",
   status(read(), sharedAvailable: shared)]
  if let s = read(), let data = try? JSONEncoder().encode(s), let text = String(data: data, encoding: .utf8) {
   lines.append("Extension reported snapshot (not main entitlements): " + text)
  }
  lines.append("No shared heartbeat cannot distinguish not launched / crash / missing shared permission. Private extension fallback is not readable by main app.")
  return lines.joined(separator:"\n")
 }
 static var statusText: String { status(read(), sharedAvailable: Store.root != nil) }
 static var exportLogText: String {
  guard let root = Store.root else { return "Extension events unavailable: no main shared container; private extension log is not readable." }
  let url=root.appendingPathComponent(logRelativePath)
  guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,
        size > 0, size <= maximumBytes,
        let data=try? Data(contentsOf:url), data.count <= maximumBytes,
        let events=try? JSONDecoder().decode([CaptureLogEntry].self,from:data),
        events.count <= 96 else { return "Extension events unavailable: no valid shared event log." }
  let formatter=ISO8601DateFormatter()
  return events.map { entry in
   let domain=entry.domain.flatMap {
    ["NSURLErrorDomain","NSPOSIXErrorDomain","Soniox","LiveSubs","OSStatus","Other"].contains($0) ? $0 : nil
   } ?? "-"
   return formatter.string(from:entry.time) + " " + entry.event.rawValue +
    " domain=" + domain + " code=" + (entry.code.map(String.init) ?? "-")
  }.joined(separator:"\n")
 }
 static var mergedDiagnostics: String { SharedSigning.diagnosticText + "\n" + diagnosticText }
}

private final class CaptureRecorder: @unchecked Sendable {
 private let lock = NSLock()
 private var snapshot = CaptureSnapshot()
 private var events: [CaptureLogEntry] = []
 private var root: URL?
 private var timer: DispatchSourceTimer?
 private var active = false
 private var lastFlush = Date.distantPast
 // Deliberately no Soniox, converter, group discovery or Security at construction.
 func begin() {
  lock.lock(); defer { lock.unlock() }
  timer?.cancel(); timer = nil
  snapshot = CaptureSnapshot()
  snapshot.bundleID = String((Bundle.main.bundleIdentifier ?? "(missing)").prefix(256))
  events = []; active = true
  root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
  append(.entered); flush(critical:true) // private durable earliest evidence
 }
 func discover() {
  lock.lock(); defer { lock.unlock() }
  guard active else { return }
  // Executes in the extension's own process. Main app probes are not reused.
  let resolved = SharedSigning.resolved
  snapshot.group = resolved?.group
  snapshot.container = resolved != nil
  if let shared = resolved?.root { root = shared }
  append(.discovered); flush(critical:true)
  let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label:"capture.heartbeat"))
  t.schedule(deadline:.now()+3,repeating:3)
  t.setEventHandler { [weak self] in self?.tick() }
  timer = t; t.resume()
 }
 private func tick() {
  lock.lock(); defer { lock.unlock() }
  guard active else { return }; flush(critical:false)
 }
 private func append(_ event: CaptureEvent, code: Int? = nil, domain: String? = nil) {
  events.append(CaptureLogEntry(time:Date(), event:event, code:code, domain:domain))
  if events.count > 96 { events.removeFirst(events.count-96) }
 }
 func event(_ e: CaptureEvent, code: Int?, domain: String?) {
  lock.lock(); defer { lock.unlock() }
  guard active else { return }
  let safeDomain = domain.flatMap { ["NSURLErrorDomain","NSPOSIXErrorDomain","Soniox","LiveSubs","OSStatus"].contains($0) ? $0 : "Other" }
  switch e {
  case .started, .resumed: snapshot.lifecycle = "started"
  case .paused: snapshot.lifecycle = "paused"
  case .stopped: snapshot.lifecycle = "stopped"
  case .fatal: snapshot.lifecycle = "failed"
  case .connecting:
   if snapshot.lifecycle == "failed" { snapshot.lifecycle = "started" }
   snapshot.transport = "connecting"; snapshot.authentication = "pending"; snapshot.errorCode=nil; snapshot.errorDomain=nil
  case .transportOpen: if snapshot.transport != "configured" { snapshot.transport = "open" }
  case .configSent: snapshot.transport = "configured" // NOT authentication proof
  case .protocolConfirmed: snapshot.authentication = "confirmed"
  case .transportError: snapshot.transport = "error"
  case .protocolError:
   if code == 401 || code == 403 { snapshot.authentication = "failure" }
   else { snapshot.lifecycle = "failed" }
  case .serverFinished: snapshot.transport = "closed"
  default: break
  }
  if let code = code { snapshot.errorCode = code; snapshot.errorDomain = safeDomain }
  append(e,code:code,domain:safeDomain); flush(critical:true)
  if e == .stopped { active=false;timer?.cancel();timer=nil }
 }
 func keyRead(_ success: Bool, _ status: Int32) {
  lock.lock(); defer { lock.unlock() }
  guard active else { return }
  snapshot.keySuccess=success; snapshot.keyOSStatus=status
  append(.keyRead,code:Int(status),domain:"OSStatus");flush(critical:true)
 }
 func audio(_ frames: Int) {
  lock.lock(); defer { lock.unlock() }
  guard active else { return }
  snapshot.audioAppBuffers &+= 1
  snapshot.audioAppFrames &+= UInt64(max(0,frames))
  snapshot.lastAudio=Date()
  // No file IO and no async closure per buffer. Timer aggregates every 3 sec.
 }
 func tokens(_ source: Int, _ translation: Int) {
  lock.lock(); defer { lock.unlock() }
  guard active else { return }
  snapshot.sourceTokens &+= UInt64(max(0,source)); snapshot.translationTokens &+= UInt64(max(0,translation))
  if source > 0 { snapshot.lastSource=Date() }
  if translation > 0 { snapshot.lastTranslation=Date() }
 }
 private func flush(critical: Bool) {
  guard let root = root else { return }
  snapshot.heartbeat=Date()
  // TASK_BASIC_INFO is a tiny kernel query, no framework/library allocation.
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
  let kr = withUnsafeMutablePointer(to:&info) { pointer in
   pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
   }
  }
  if kr == KERN_SUCCESS {
   snapshot.residentBytes=UInt64(info.resident_size)
   snapshot.peakResidentBytes=max(snapshot.peakResidentBytes,snapshot.residentBytes)
   snapshot.memorySamples &+= 1
  }
  write(snapshot,to:root.appendingPathComponent(CaptureIPC.relativePath),critical:critical)
  // Rolling event file is also bounded. Critical transitions are durable.
  write(events,to:root.appendingPathComponent(CaptureIPC.logRelativePath),critical:critical)
  lastFlush=Date()
 }
 private func write<T: Encodable>(_ value: T, to url: URL, critical: Bool) {
  guard let data = try? JSONEncoder().encode(value), data.count <= CaptureIPC.maximumBytes else { return }
  do {
   try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
   try data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
   if critical {
    let fd = open(url.path,O_RDONLY)
    if fd >= 0 { _ = fsync(fd); close(fd) }
    let directory = open(url.deletingLastPathComponent().path,O_RDONLY)
    if directory >= 0 { _ = fsync(directory); close(directory) }
   }
  } catch { /* Never log errors containing paths or serialized payloads. */ }
 }
}
