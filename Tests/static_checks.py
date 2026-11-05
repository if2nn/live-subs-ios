"""Source/plist contract guards PLUS execution of the shipped Foundation-only
feature code (audio decode/resample, Soniox config, settings, history).
Missing swiftc is a failure: behavior is never reported as passing unrun."""
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
def text(name):
    return (root / name).read_text()

checks = 0
def check(value, description):
    global checks
    assert value, description
    checks += 1

project = text("project.yml")
handler = text("Broadcast/SampleHandler.swift")
socket = text("Shared/Soniox.swift")
store = text("Shared/Core.swift")
signing = text("Shared/Signing.swift")
pip = text("App/CaptionPiP.swift")
renderer = text("App/CaptionRenderer.swift")
app = text("App/LiveSubsApp.swift")
stores = text("App/Stores.swift")
diagnostics = text("App/Diagnostics.swift")
audio = text("Shared/AudioPCM.swift")

# Build configuration.
check('SWIFT_VERSION: "6.0"' in project and 'SWIFT_STRICT_CONCURRENCY: complete' in project, "strict Swift 6 build")
check('INFOPLIST_FILE: App/Info.plist' in project and 'INFOPLIST_FILE: Broadcast/Info.plist' in project, "supplied plists")
check('    info:' not in project, "XcodeGen must not regenerate supplied plists/entitlements")
check('iOS: "27.0"' in project, "iOS 27 deployment target")
for folder, filename in [("App", "LiveSubs.entitlements"), ("Broadcast", "Broadcast.entitlements")]:
    info = plistlib.loads((root / folder / "Info.plist").read_bytes())
    ent = plistlib.loads((root / folder / filename).read_bytes())
    check(info["SharedAppGroupCandidates"] == ["group.com.aian.livesubs"], "identical group candidates")
    check(ent["com.apple.security.application-groups"] == ["group.com.aian.livesubs"], "declared app group")
    check("keychain-access-groups" not in ent, "no unresolved AppIdentifierPrefix")
    check(b"$(" not in plistlib.dumps(ent), "concrete entitlement metadata")
    check(info["CFBundleVersion"] == "5", "preview 5 build version")
check('audio' in plistlib.loads((root / 'App/Info.plist').read_bytes())['UIBackgroundModes'], "PiP background audio mode")

# Audio path: explicit decoding, no AVAudioConverter guesswork.
check('AVAudioConverter' not in handler, "no AVAudioConverter in extension audio path")
check('CMAudioFormatDescriptionGetStreamBasicDescription' in handler and 'PCMDescriptor.from(' in handler, "ASBD-driven decode")
check('CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer' in handler, "copy-free buffer list access")
check('kAudioFormatFlagIsBigEndian' in audio or '0x2 != 0' in audio, "big-endian handled")
check('SpeechChunker' in handler and 'chunkSamples = 1_600' in audio, "100 ms audio frames")
check('CaptureIPC.audioFormat(' in handler and 'CaptureIPC.audioLevel(' in handler, "audio format and level diagnostics")
check('CaptureIPC.audioSent(' in socket and 'CaptureIPC.audioDropped(' in socket, "sent/dropped byte counters")
check('final_audio_proc_ms' in socket, "server-processed audio evidence")

# Soniox protocol.
check('SonioxConfig.json(settings.languages)' in handler, "extension uses chosen languages")
check('socket.send(.string(self.config))' in socket, "config from settings")
check('"api_key"' not in socket and 'Authorization' in socket, "key only in Authorization header")
check('self.ws?.send(.string(""))' in socket, "empty TEXT terminator")
check('if ending {completeEnd(false);return}' in socket, "ending cannot retry")
check('done.wait(timeout: .now() + 1.5)' in handler, "bounded ReplayKit wait")

# PiP: persistent controller, no readiness gate, IOSurface BGRA, recovery without rebuild.
check(pip.count('AVPictureInPictureController(contentSource:') == 1, "one controller construction site")
check('guard controller == nil else { return }' in pip, "controller is never recreated")
check('.isReadyForDisplay' not in pip, "no isReadyForDisplay readiness gate")
check('kCVPixelFormatType_32BGRA' in renderer and 'kCVPixelBufferIOSurfacePropertiesKey' in renderer, "IOSurface BGRA frames")
check('kCVPixelFormatType_32ARGB' not in renderer, "no ARGB frames")
check('kCMSampleAttachmentKey_DisplayImmediately' in pip, "display immediately")
check('layer.flush()' in pip and 'AVSampleBufferDisplayLayer()' in pip and pip.count('AVSampleBufferDisplayLayer()') == 1, "flush, never rebuild layer")
check('canStartPictureInPictureAutomaticallyFromInline = true' in pip, "auto PiP when leaving app after one tap")
check('UIColor.black.cgColor' in renderer, "PiP canvas always black")
check(pip.count('nonisolated func') >= 9, "nonisolated AVKit callbacks")
check('{ @Sendable observed, _ in' in pip, "KVO callback not main-actor isolated")
check('restoreUserInterfaceForPictureInPictureStop' in pip, "restore UI delegate")

# One-tap flow and stop prompt.
check('func oneTapStart()' in pip and 'launcher.open()' in pip, "one tap opens system picker")
check('sendActions(for: .touchUpInside)' in pip, "public UIControl action on picker")
check('录屏已停止' in pip and 'phaseChanged' in pip, "recording stopped prompt")

# Features.
check('Tab("历史"' in app and 'HistoryDetailView' in app and 'history.delete' in app, "history page")
check('UIPasteboard.general.string = entry.plainText(mode)' in app and 'ShareLink(items:' in app, "copy and share")
check('settings.source' in app and 'settings.target' in app and 'settings.display' in app, "language and display settings")
check('.preferredColorScheme(.dark)' not in app, "appearance no longer forced dark")
check('settings.appearance' in app and 'AppearanceMode' in app, "appearance control follows system/light/dark")
for ident in ["settings.fontSize", "settings.lines", "settings.translationColor", "settings.opacity", "settings.order", "settings.position"]:
    check(ident in app, "style control " + ident)
check('DiagnosticsView' in app, "diagnostics page kept")
check('.buttonStyle(.glassProminent)' in app and '.buttonStyle(.glass)' in app, "Liquid Glass on controls")
check('.glassEffect(' not in app, "HIG: no Liquid Glass in the content layer")
_renderer = text("App/CaptionRenderer.swift")
check("CaptionCanvas.make(screenScale:" in _renderer and "context.scaleBy(x: CGFloat(canvas.scale)" in _renderer, "render in points at screen scale")
check(".strokeWidth" not in _renderer and "shadowBlurRadius" not in _renderer, "no stroke/blur softening glyph edges")
check("didTransitionToRenderSize" in text("App/CaptionPiP.swift") and "renderer.renderSize =" in text("App/CaptionPiP.swift"), "PiP render size drives the frame")
check("static let width = 1280" not in _renderer, "fixed 1280 px canvas removed")
check("var originalLive" in _renderer and "var translatedLive" in _renderer and "content.originalLive" in _renderer, "renderer content carries live sentence")
check('@Observable' in stores and '@Observable' in pip, "Observation models")
check('ObservableObject' not in app + pip + stores, "no legacy ObservableObject")
check('Store.writeHistory' in handler and 'importShared' in stores, "history written by extension, imported by app")

# Credentials and privacy.
check('SecItemUpdate' in store and store.index('SecItemUpdate') < store.index('SecItemAdd'), "update before add")
check('SecTaskCopyValueForEntitlement' not in signing, "no private entitlement API")
check('status: keychainStatus(candidate)' in signing, "shared Keychain authorization probe")
check('namespaces' in diagnostics and 'allSatisfy' in diagnostics, "diagnostic events are fixed identifiers")
check('Diagnostics.record(' not in handler, "extension does not use app log")
for name in ["Shared/Soniox.swift", "Broadcast/SampleHandler.swift", "App/Diagnostics.swift", "Shared/CaptureIPC.swift"]:
    src = text(name)
    check('print(' not in src and 'NSLog(' not in src and 'os_log(' not in src, "no console logging in " + name)
for path in root.rglob("*"):
    if not path.is_file() or any(part in {".git", "build", "dist", "__pycache__", "simulator-build", "simulator-artifacts"} for part in path.parts):
        continue
    data = path.read_bytes()
    check(not re.search(rb"(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}", data), "no GitHub token pattern")
    check(not re.search(rb"/home/(?:kit|admin)/|192[.]168[.]|10[.]33[.]33[.]", data), "no internal paths/network")
print(f"{checks} static source/plist guards PASS")

compiler = shutil.which("swiftc")
if not compiler:
    raise SystemExit("swiftc unavailable: feature behavior tests NOT RUN (run in macOS CI)")
with tempfile.TemporaryDirectory() as tmp:
    exe = str(Path(tmp) / "feature-tests")
    subprocess.run([compiler, "-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete",
                    *[str(root / f) for f in ["Shared/AudioPCM.swift", "Shared/Settings.swift", "Shared/History.swift", "Shared/CaptionLayout.swift",
                                              "Shared/Transcript.swift", "Tests/FeatureTests.swift"]],
                    "-o", exe], check=True)
    subprocess.run([exe], check=True)
