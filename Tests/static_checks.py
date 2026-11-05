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
app = text("App/DualApp.swift")
stores = text("App/Stores.swift")
diagnostics = text("App/Diagnostics.swift")
audio = text("Shared/AudioPCM.swift")

# Build configuration.
check('SWIFT_VERSION: "6.0"' in project and 'SWIFT_STRICT_CONCURRENCY: complete' in project, "strict Swift 6 build")
check('INFOPLIST_FILE: App/Info.plist' in project and 'INFOPLIST_FILE: Broadcast/Info.plist' in project, "supplied plists")
check('    info:' not in project, "XcodeGen must not regenerate supplied plists/entitlements")
check('iOS: "27.0"' in project, "iOS 27 deployment target")
for folder, filename in [("App", "Dual.entitlements"), ("Broadcast", "Broadcast.entitlements")]:
    info = plistlib.loads((root / folder / "Info.plist").read_bytes())
    ent = plistlib.loads((root / folder / filename).read_bytes())
    check(info["SharedAppGroupCandidates"] == ["group.com.aian.livesubs"], "identical group candidates")
    check(ent["com.apple.security.application-groups"] == ["group.com.aian.livesubs"], "declared app group")
    check("keychain-access-groups" not in ent, "no unresolved AppIdentifierPrefix")
    check(b"$(" not in plistlib.dumps(ent), "concrete entitlement metadata")
    check(info["CFBundleVersion"] == "6", "preview 6 build version")
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
check('RecordsView' in app and 'records.open' in app and 'settings.records' in app and 'HistoryDetailView' in app and 'history.delete' in app, "records reachable from pages and settings")
for tab in ['Tab(S.tabCaptions', 'Tab(S.tabInterpret', 'Tab(S.tabTranscribe', 'Tab(S.tabSettings']:
    check(tab in app, "preview 6 tab " + tab)
for word, ident in [("字幕", "tabCaptions"), ("同传", "tabInterpret"), ("转录", "tabTranscribe"), ("设置", "tabSettings")]:
    check(f'static let {ident} = "{word}"' in text("App/Strings.swift"), "tab label " + word)
check('Tab("历史"' not in app and 'Tab("诊断"' not in app and 'Tab(' not in app.replace('Tab(S.', ''), "history and diagnostics moved into settings")
for ident in ["settings.apiKey", "settings.styleLink", "settings.diagnostics"]:
    check(ident in app, "settings subpage " + ident)
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
# Preview 6 copy rules (plan §3.6): page copy lives in App/Strings.swift, short and plain;
# explanations live in App/Manual.swift.
strings = text("App/Strings.swift")
manual = text("App/Manual.swift")
cjk = re.compile(r"[\u4e00-\u9fff]")
def literals(src):
    return re.findall(r'"([^"\n]*)"', src)
for lit in literals(strings):
    check(len(cjk.findall(lit)) <= 20, "page copy at most 20 CJK chars: " + lit)
    for word in ["你", "我们", "将会"]:
        check(word not in lit, "no " + word + " in page copy: " + lit)
for name in ["App/DualApp.swift", "App/CaptionPiP.swift", "App/Stores.swift", "App/Diagnostics.swift"]:
    for lit in literals(text(name)):
        check(len(cjk.findall(lit)) <= 40, "no long explanation in " + name + ": " + lit)
app_literals = [l for l in literals(app) if cjk.search(l)]
check(app_literals == ["这是说话人刚才说的话。"], "DualApp.swift uses S.* for copy (only the preview sample is inline): " + repr(app_literals))
for old in ["听见世界", "怎么用", "还没有字幕记录", "未确认尾句", "每种文字最多"]:
    check(old not in app + strings, "old copy removed: " + old)
check('ManualView()' in app and 'settings.manual' in app and 'live.manual' in app, "manual reachable from settings and captions page")
for chapter in ['"setup"', '"captions"', '"interpret"', '"transcribe"', '"records"', '"privacy"', '"faq"']:
    check("id: " + chapter in manual, "manual chapter " + chapter)
check("start.goToSettings" in app, "no-key prompt has a 去设置 action")
# App icons (plan §12.8): 7 sets x light/dark/tinted at 1024, light opaque,
# tinted grayscale, 7 previews, alternate list in project.yml matches.
import json as _json, struct as _struct, zlib as _zlib
def _png_info(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} not PNG"
    w, h, depth, ctype = _struct.unpack(">IIBB", data[16:26])
    return w, h, ctype   # ctype 2 RGB, 6 RGBA, 4 gray+alpha, 0 gray
_assets = root / "App/Assets.xcassets"
_names = ["AppIcon"] + [f"AppIcon-{c}" for c in ["Blue", "Green", "Pink", "Yellow", "Purple", "Teal"]]
for _n in _names:
    _d = _assets / f"{_n}.appiconset"
    _c = _json.loads((_d / "Contents.json").read_text())
    _looks = {tuple(a["value"] for a in img.get("appearances", [])): img["filename"] for img in _c["images"]}
    check(set(_looks) == {(), ("dark",), ("tinted",)}, f"{_n} has light, dark and tinted")
    for _look, _file in _looks.items():
        _w, _h, _t = _png_info(_d / _file)
        check((_w, _h) == (1024, 1024), f"{_n} {_file} is 1024")
        if _look == (): check(_t == 2, f"{_n} light icon has no alpha")
        if _look == ("tinted",): check(_t in (0, 4), f"{_n} tinted icon is grayscale")
for _c in ["Orange", "Blue", "Green", "Pink", "Yellow", "Purple", "Teal"]:
    _p = _assets / f"IconPreview-{_c}.imageset"
    check((_p / "light.png").is_file() and (_p / "dark.png").is_file(), f"preview {_c}")
    check(_png_info(_p / "light.png")[:2] == (180, 180), f"preview {_c} is 180")
_yml = (root / "project.yml").read_text()
check('ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: "' + " ".join(_names[1:]) + '"' in _yml, "alternate icon list matches catalog")
check((root / "Design/Icon/render_icons.py").is_file() and (root / "Design/Icon/colors.json").is_file() and (root / "Design/Icon/dual-icon.svg").is_file(), "icon sources in Design/Icon")
_icons_src = (root / "App/AppIcons.swift").read_text()
check("supportsAlternateIcons" in _icons_src and "setAlternateIconName" in _icons_src and "alternateIconName" in _icons_src, "icon picker uses the system as source of truth")

# S1.5 rename to Dual: names change, identity that holds data does not.
_yml2 = (root / "project.yml").read_text()
check(_yml2.startswith("name: Dual\n") and "  Dual:\n" in _yml2 and "DualUITests" in _yml2, "project, target and scheme are Dual")
check("PRODUCT_BUNDLE_IDENTIFIER: com.aian.livesubs\n" in _yml2 and "PRODUCT_BUNDLE_IDENTIFIER: com.aian.livesubs.broadcast" in _yml2, "bundle ids unchanged")
for _pl in ["App/Info.plist", "Broadcast/Info.plist"]:
    check("<string>Dual</string>" in (root / _pl).read_text() and "双语字幕" not in (root / _pl).read_text(), f"{_pl} display name Dual")
_core = (root / "Shared/Core.swift").read_text()
check('"LiveSubs.Private" : "LiveSubs"' in _core, "keychain service names unchanged (Key survives upgrade)")
check('"LiveSubs.settings.v1"' in (root / "App/Stores.swift").read_text() and '"LiveSubs.history.deleted"' in (root / "App/Stores.swift").read_text(), "UserDefaults keys unchanged")
_wf = (root / ".github/workflows/live-subs-ios.yml").read_text()
check("Dual-unsigned.ipa" in _wf and "LiveSubs-unsigned.ipa" not in _wf and "Dual.xcodeproj" in _wf, "workflow builds Dual-unsigned.ipa")

print(f"{checks} static source/plist guards PASS")

compiler = shutil.which("swiftc")
if not compiler:
    raise SystemExit("swiftc unavailable: feature behavior tests NOT RUN (run in macOS CI)")
with tempfile.TemporaryDirectory() as tmp:
    exe = str(Path(tmp) / "feature-tests")
    subprocess.run([compiler, "-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete",
                    *[str(root / f) for f in ["Shared/AudioPCM.swift", "Shared/Settings.swift", "Shared/History.swift", "Shared/CaptionLayout.swift",
                                              "Shared/Transcript.swift", "Shared/Interpret.swift", "Tests/FeatureTests.swift"]],
                    "-o", exe], check=True)
    subprocess.run([exe], check=True)
    # 音频转录 job state machine against a fake transport (no network).
    exe2 = str(Path(tmp) / "transcribe-tests")
    subprocess.run([compiler, "-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete",
                    *[str(root / f) for f in ["Shared/AudioPCM.swift", "Shared/Settings.swift", "Shared/History.swift", "Shared/CaptionLayout.swift",
                                              "Shared/Transcript.swift", "Shared/Interpret.swift", "Shared/SonioxAsync.swift", "Tests/TranscribeTests.swift"]],
                    "-o", exe2], check=True)
    subprocess.run([exe2], check=True)
