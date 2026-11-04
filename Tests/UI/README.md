# iOS 27 simulator release gate

This gate launches the real app and presses its public PiP button, without invoking
the broadcast picker. The PiP result is attached as unsupported, controlledfail or
actualdidstart; a pending/unclassified result, crash or backgrounded app fails.
Simulator success does not establish device PiP, SideStore signing or cross-app capture.

Every CI run creates a new disposable iPhone on an installed available iOS 27
runtime. It never reuses a device with pre-existing Keychain data, never reads
environment credentials and types only the invalid placeholder from the test.
The Debug-only launch-argument-gated accessibility indicator exposes saved length,
not credential contents. Restart plus save and invalid-key connection failure are
required. The real network path is used, with the app's existing roughly 9-second
timeout and a 20-second XCTest ceiling; a success response fails this test.

Only the simulator xcodebuild command overrides signing to ad-hoc and supplies
empty simulator entitlements. Device app and broadcast extension signing metadata
remain unchanged. This intentionally does not validate extension shared groups.

The workflow always collects xcresult (including launch/PiP/error screenshots),
a final simctl screenshot, target-process unified log, fresh target-app crash reports
and Documents diagnostics. Missing required evidence or target crash reports fail
the job. Device packaging depends on this job succeeding. Do not publish preview 2
until the actual Actions simulator job passes and its evidence is reviewed.

Local Linux checks validate Python syntax and source/plist guards only. Xcode,
XCTest and simulator runtime execution must run on the configured Xcode 27 runner.
