# Live Subs (双语字幕) for iOS

An experimental iOS 27+ app that shows live bilingual captions for audio playing in other apps. A ReplayKit broadcast upload extension captures **app audio only** (no microphone, no video frames). It streams that audio to **your own** Soniox account for real-time transcription and translation. The captions appear in a sample-buffer Picture-in-Picture window, Netflix-style: an opaque black strip with outlined text.

Built with Swift 6 (strict concurrency), SwiftUI, Observation (`@Observable`) and Liquid Glass. It uses public APIs only. It is meant for personal SideStore signing and is built unsigned on GitHub Actions with Xcode 27.2 and the iOS 27.2 SDK.

> Status: preview. Simulator UI tests and offline behavior tests pass in CI. **Nothing here is device-accepted** until it is checked on a real iPhone; see "Device-only checks" below.

## How to use

1. Open **设置** (Settings). Save your Soniox API key. The key is stored only in the iOS Keychain; it never goes into captions, history, logs or diagnostics. Choose:
   - the source language: 自动识别 (auto-detect) or a fixed language
   - the target language
   - the display mode: 双语 (bilingual), 仅译文 (translation only) or 仅原文 (original only)
   - the caption style: font size, translation and original colors, lines per lane, translation-above-original order, and position
2. On **字幕** (Captions), tap **开始** (Start). Live Subs does three things:
   - It opens the caption PiP window if iOS allows it right away. It also arms auto-PiP, so captions float as soon as you leave the app.
   - It raises the system broadcast sheet.
   - It keeps a silent audio session running so the app can keep drawing captions in the background.
3. In the system sheet, pick **双语字幕** and tap **开始直播** (Start Broadcast). iOS gives apps no public API to start a broadcast, so this one tap always belongs to you. That is the closest public-API version of the one-tap flow.
4. Play your video. When the system recording stops, the PiP window and the app both say **录屏已停止** (recording stopped). Tap **重新开始** (start again) to reopen it.
5. **历史** (History) keeps the full caption text of every session inside the app. You can view it as bilingual, original only or translation only. You can copy it, share it as .txt or .srt, or delete it. Swipe or use the trash button to delete. A deleted session is never re-imported.
6. **诊断** (Diagnostics) shows signing and shared-container probes and extension heartbeat counters. It also shows the audio format, levels and sent bytes, and Soniox processed-audio milliseconds. Diagnostics can be copied or exported. They never contain the key, caption text or audio.

## Preview 5 changes

- **Sharper PiP captions.** Preview 4 drew a 1280-pixel-wide frame (1280×404), with font sizes in raw pixels, a black stroke and a blurred shadow. The stroke and shadow ate into glyph edges on the black canvas.
  - Captions are now laid out in points on a fixed 480×160 pt strip (`Shared/CaptionLayout.swift`) and rasterised at the screen scale: 1440×480 on a 3x iPhone.
  - When AVKit reports the PiP render size (`didTransitionToRenderSize`), the frame is re-rendered at exactly the pixels it occupies in that window, so it is shown 1:1.
  - Stroke and blur are gone, line heights are fixed, and text uses subpixel glyph positioning.
  - Diagnostics record `pip.screen.scale`, `pip.renderSize.*` and `pip.frame.*`.
- **Caption strip.** The PiP window is a 3:1 strip, wide and flat, about two lines per lane in bilingual mode at the default size. Larger fonts reduce the line count or scale down to fit.
- **Tests.** FeatureTests check the canvas size per screen scale and render size, plus the typography budget. A simulator UI test checks that the frame is 480 pt × the screen scale and 3:1, and CI keeps the rendered frame PNG as evidence. The simulator is not the device: Ian confirms real PiP sharpness.

## Preview 4 changes

### Captions now come out (audio path rewrite)

Preview 3 received 1,063,936 app-audio frames and Soniox confirmed the session, but returned zero tokens. The old path guessed the input layout through `AVAudioFormat(cmAudioFormatDescription:)` and `AVAudioConverter`.

The extension now reads the `AudioStreamBasicDescription` and decodes exactly what ReplayKit delivers:

- 8/16/24/32-bit integer or 32/64-bit float
- big- or little-endian
- interleaved or planar

It then downmixes to mono and resamples to 16 kHz with a stateful box-filter resampler. It sends 100 ms little-endian `s16le` frames.

The preview 3 root cause is **not proven**. A layout mismatch is the leading suspect: ReplayKit app audio has often been reported as big-endian 16-bit PCM, and a mismatch turns speech into noise that a recognizer returns no words for. The other suspects are a silent or protected source and a converter that produced nothing usable. Offline tests run the shipped decoder on nine layouts, including that one, and check frequency, amplitude and drift. They also show that an endianness mismatch is detectable.

New diagnostics separate the remaining possibilities on a device:

- delivered frames vs bytes actually sent
- the detected format
- peak level (a silent or protected source)
- Soniox `final_audio_proc_ms` / `total_audio_proc_ms`
- dropped bytes

### PiP opens on the first tap

Preview 3 recreated the `AVPictureInPictureController` on every tap and waited for the layer's `isReadyForDisplay`. That never became true on the device, so it timed out (code 2).

Now:

- **One layer and one controller** live for the whole app session. The controller is created as soon as the layer is in a window.
- **No `isReadyForDisplay` gate.** The only precondition is the controller's own `isPictureInPicturePossible`, observed with KVO. One tap is one request; it starts as soon as PiP is possible, with one silent retry if the system drops the call.
- Frames are **IOSurface-backed 32BGRA** from a pixel-buffer pool, with `DisplayImmediately`. They are fed continuously and re-fed every second. Preview 3 used non-IOSurface 32ARGB.
- A failed renderer (`-11847 Operation interrupted` after backgrounding) is **flushed and fed again**. The layer and controller are never rebuilt.
- `canStartPictureInPictureAutomaticallyFromInline` is armed after Start, so leaving the app opens PiP even if the in-app start was not yet allowed.

## Build

`project.yml` is the XcodeGen spec; run `xcodegen generate`. CI (`.github/workflows/live-subs-ios.yml`) has two stages:

1. It runs the simulator UI gate on a fresh iOS 27 simulator. It needs no real credential and uses a fixed invalid placeholder key.
2. It then:
   - runs the static and behavior checks and the Swift test executables
   - builds the unsigned device app
   - ad-hoc signs the extension, then the app, to embed App Group entitlement metadata for the personal re-signer
   - verifies the bundle and packages `LiveSubs-unsigned.ipa` with `SHA256SUMS`

"Unsigned" means no development or distribution identity or provisioning profile. Ad-hoc signatures do not authorize installation.

The Foundation-only tests run anywhere with a Swift 6 toolchain: `python3 Tests/static_checks.py` (also runs `Tests/FeatureTests.swift`), `Tests/capture_ipc_checks.py` and `Tests/pip_policy_checks.py`.

## Signing and sharing

The app and the extension share one runtime resolver. It uses three sources:

- provisioning-profile hints, decoded as bounded XML
- configured `SharedAppGroupCandidates`
- bundle-ID-derived candidates, including SideStore's team-suffixed `group.com.aian.livesubs.<TEAMID>`

Each candidate is checked with real OS probes: `containerURL(forSecurityApplicationGroupIdentifier:)` and SecItem add/remove. No private entitlement API is used. The preview 3 device showed the team-suffixed group working in both the app and the extension (`keySuccess: true`).

## Device-only checks (not verified by CI or the simulator)

- PiP opens on the first tap on a real iOS 27 device, and stays visible over other apps.
- The background silent-audio keep-alive keeps captions updating while another app plays. Also check that it neither ducks nor stops the other app's sound.
- Real system-audio capture produces Soniox source and translation tokens. Check the diagnostics format line, peak level and `serverTotalAudioMS`.
- DRM-protected players may hand ReplayKit silence. The diagnostics would show a peak level below −60 dBFS.
- iPhone shows one PiP at a time; a video app's own PiP replaces the caption window.
- `sendActions` on the system picker's button raises the broadcast sheet. If iOS changes the picker's view structure, tap the small record button instead.
- The stop prompt appears in PiP and in the app after the recording ends.
- SideStore re-signing of both targets, shared Keychain read after save, relaunch and refresh.
- Long sessions: extension memory, history file size, reconnects.

## Design references and credits

The preview 4 flow and caption window were designed after studying these projects. The ideas are credited here. **No source code was copied** from any of them; Live Subs' code is its own.

- [yuxino/Osu](https://github.com/yuxino/Osu) (MIT). An iPhone app that shows translated captions of other apps' audio in PiP via a ReplayKit broadcast. Ideas used:
  - lyric-style emphasis: the current sentence bright, earlier context dimmed
  - a black caption canvas
  - "Start" goes straight to the system broadcast sheet
  - IOSurface BGRA frames with DisplayImmediately and auto-PiP from inline
- [Chedrian07/afm-screen-translator](https://github.com/Chedrian07/afm-screen-translator) (MIT). A ReplayKit plus sample-buffer PiP translator. Ideas used:
  - its documented iOS limits: no programmatic broadcast start, PiP starts only in the foreground, PiP plus an audio session gives background runtime, and the ~50 MB extension memory budget
  - walking the user through the picker honestly
- [mgkcloud/ios-audio-capture-findings](https://github.com/mgkcloud/ios-audio-capture-findings) (no license; facts only). Device measurements of `.audioApp` on iOS 26.6: 44.1 kHz, 2 ch, 16-bit **big-endian**, 1024 frames. Always read the ASBD flags.
- [uakihir0/UIPiPView](https://github.com/uakihir0/UIPiPView) (MIT). Rendering a view into AVSampleBufferDisplayLayer for PiP.
- [phuc-nt/my-translator](https://github.com/phuc-nt/my-translator) (MIT, desktop) and [kizuna-ai-lab/sokuji](https://github.com/kizuna-ai-lab/sokuji) (AGPL-3.0, desktop; looked at only, no code used). Soniox real-time translation UX: source auto-detect, a target picker, and the user's own API key.

Apple guidance followed:

- [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials): Liquid Glass for controls and navigation only, standard materials for content.
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views): `.glass` / `.glassProminent` button styles.
- [HIG Playing video](https://developer.apple.com/design/human-interface-guidelines/playing-video).
- [Adopting Picture in Picture in a custom player](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player).

## References

- https://docs.soniox.com/api-reference/stt/websocket-api
- https://docs.soniox.com/translation/stt-translation/rt-translation
- https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player
- https://developer.apple.com/documentation/replaykit
- https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps
