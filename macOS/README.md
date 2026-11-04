# LiveSubs for macOS

Native SwiftUI app for macOS 15+. Based on iOS tag v0.1.0-preview.4 (5d4169e).
All adapted/shared copies live here. No changes to iOS or Shared originals.

Build with Swift 6 via `swift build -c release`. Run regression tests with
`swift test`. Independent macOS workflow creates an unsigned universal app ZIP.
This branch never publishes releases and never pushes to main.

## Use

Open LiveSubs, open Settings (Command-comma), save Soniox key to Keychain.
Pick source/target before starting. Grant screen/system audio permission on first use,
then restart the app if macOS asks. No microphone permission is requested.
Start listening while playing system audio. Switch between scrollable original/translation
columns and a draggable, resizable floating caption panel. Shift-command-F reopens the panel.
Floating subtitles default to small gray original and large white translated text.

Languages, caption visibility, size, colors, line count, order, position and opacity
are configurable. Live language changes require stopping the session.
History is autosaved locally every two seconds and on stop in
~/Library/Application Support/LiveSubsMac/History. Export selected sessions as TXT/SRT.
Translation timestamps/alignment are approximate, matching preview.4 semantics.
Partial text is preserved in JSON and TXT, not exported as final SRT.

## Privacy / limitations

Only captured audio goes to Soniox. No audio/video files are recorded.
Key is stored using Security.framework, never in settings/history or logs.
Capture uses the first available display's system audio, excluding LiveSubs itself.
Protected content may be silent. No DRM bypass.
Floating windows use floating level and fullScreenAuxiliary; behavior over every
fullscreen app needs real Mac testing.
CI build/tests do not verify system permission UI, audible capture, live credentials,
translation quality, Keychain persistence, Retina rendering, or fullscreen behavior.
Unsigned/non-notarized app may be blocked by Gatekeeper. Do not disable Gatekeeper globally;
use normal macOS per-app open approval for software you trust.

## Provenance

Copied from preview.4: AudioPCM, Settings, Transcript, History, CaptureState, Soniox.
Soniox removes ReplayKit IPC diagnostics only; retains authentication header, v6 model,
endpoint handling, bounded reconnect and text-frame finish protocol.
Apple sample reference:
https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
