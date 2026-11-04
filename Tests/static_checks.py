"""Offline source/plist guards only. This does not compile or execute Swift."""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
def text(name):
    return (root / name).read_text()

transcript = text("Shared/Transcript.swift")
socket = text("Shared/Soniox.swift")
handler = text("Broadcast/SampleHandler.swift")
store = text("Shared/Core.swift")
signing = text("Shared/Signing.swift")
app = text("App/LiveSubsApp.swift")
project = text("project.yml")
checks = 0
def check(value, description):
    global checks
    assert value, description
    checks += 1

check('SWIFT_VERSION: "6.0"' in project and 'SWIFT_STRICT_CONCURRENCY: complete' in project, "strict Swift 6 build")
check('INFOPLIST_FILE: App/Info.plist' in project and 'INFOPLIST_FILE: Broadcast/Info.plist' in project, "preserve supplied plists")
check('    info:' not in project, "do not regenerate supplied signing and broadcast configuration")
for folder, filename in [("App", "LiveSubs.entitlements"), ("Broadcast", "Broadcast.entitlements")]:
    info = plistlib.loads((root / folder / "Info.plist").read_bytes())
    ent = plistlib.loads((root / folder / filename).read_bytes())
    check(info["SharedAppGroupCandidates"] == ["group.com.aian.livesubs"], "identical group candidates")
    check("group.com.aian.livesubs" in ent["com.apple.security.application-groups"], "declared app group")
    check("keychain-access-groups" not in ent, "no unresolved AppIdentifierPrefix")
    check(b"$(" not in plistlib.dumps(ent), "concrete entitlement metadata")
    check(info["CFBundleVersion"] == "2", "preview 2 build version")
check('-> [Segment]' in transcript and 'var source = Lane()' in transcript and 'var target = Lane()' in transcript, "independent segment lanes")
check('approximate: lane == .translation' in transcript, "translation approximate")
check('self.ws?.send(.string(""))' in socket, "empty TEXT terminator")
check(socket.index('self.onMessage?(obj)') < socket.index('if obj["finished"]'), "tokens before finished")
check('if ending {completeEnd(false);return}' in socket, "ending cannot retry")
check('self.ending' in socket and 'self.queue.asyncAfter' in socket, "bounded ending")
check('done.wait(timeout:.now()+1.2)' in handler, "bounded ReplayKit wait")
check('persist();publish(true)' in handler and 'recovery.json' in handler, "recovery snapshot")
check('SecItemUpdate' in store and store.index('SecItemUpdate') < store.index('SecItemAdd'), "update before add")
check('SecItemDelete' not in store, "never delete saved credential before replace")
check('SecTaskCopyValueForEntitlement' not in signing, "no unavailable entitlement API")
check('status: keychainStatus(candidate)' in signing, "shared Keychain authorization probe")
check('ProfileHints.candidates' in signing and 'ProfileHints.decode' in signing, "profile-hint dynamic discovery")
check('LiveSubs.Private' in store and 'SharedSigning.isExtension' in store, "private save without extension leakage")
check('derivedPrivateID' in signing and 'privateIDs.first { keychainStatus($0) == errSecSuccess }' in signing, "probe derived app-private group")
check('默认钥匙串；未确认私有或扩展共享' in store and 'scope.hasPrefix("共享钥匙串")' in app, "unknown default is not described as private")
check('saveScopeDescription' in store and 'diagnosticText' in signing, "visible credential and signing state")
check('ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon' in project, "AppIcon selected")
check((root / 'App/Assets.xcassets/AppIcon.appiconset/AppIcon.png').is_file(), "AppIcon asset")
check('containerURL(forSecurityApplicationGroupIdentifier:' in signing, "validate group container")
check('SharedSigning.broadcastIdentifier' in app, "embedded extension discovery")
check('["srt","txt","json"].contains' in app, "recovery exports")
picture=text("App/Picture.swift")
diagnostics=text("App/Diagnostics.swift")
check('@preconcurrency' not in picture and picture.count('nonisolated func') >= 9, "nonisolated AVKit callbacks")
check('try h.synchronize()' in diagnostics and 'previous-session.log' in diagnostics, "durable preserved events")
check('DispatchQueue' not in diagnostics and 'signal(' not in diagnostics, "no async log or unsafe signal interception")
check('Diagnostics.install()' in app and 'Diagnostics.previousSessionSummary' in app, "diagnostics installed and visible")
check('导出诊断' in app and '复制上次记录' in app, "diagnostic export and copy")
check('audio' in plistlib.loads((root/'App/Info.plist').read_bytes())['UIBackgroundModes'], "PiP background mode")
for path in root.rglob("*"):
    if not path.is_file() or any(part in {".git", "build", "dist", "__pycache__"} for part in path.parts):
        continue
    data = path.read_bytes()
    check(not re.search(rb"(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}", data), "no GitHub token pattern")
    # No internal host details belong in source or public docs.
    check(not re.search(rb"/home/(?:kit|admin)/|192[.]168[.]|10[.]33[.]33[.]", data), "no internal paths/network")
print(f"{checks} static source/plist guards PASS; Swift compile/runtime NOT performed")
