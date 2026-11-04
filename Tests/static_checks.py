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
checks = 0
def check(value, description):
    global checks
    assert value, description
    checks += 1

for folder, filename in [("App", "LiveSubs.entitlements"), ("Broadcast", "Broadcast.entitlements")]:
    info = plistlib.loads((root / folder / "Info.plist").read_bytes())
    ent = plistlib.loads((root / folder / filename).read_bytes())
    check(info["SharedAppGroupCandidates"] == ["group.com.aian.livesubs"], "identical group candidates")
    check("group.com.aian.livesubs" in ent["com.apple.security.application-groups"], "declared app group")
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
check('containerURL(forSecurityApplicationGroupIdentifier:' in signing, "validate group container")
check('SharedSigning.broadcastIdentifier' in app, "embedded extension discovery")
check('["srt","txt","json"].contains' in app, "recovery exports")
for path in root.rglob("*"):
    if not path.is_file() or any(part in {".git", "build", "dist", "__pycache__"} for part in path.parts):
        continue
    data = path.read_bytes()
    check(not re.search(rb"(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}", data), "no GitHub token pattern")
    # No internal host details belong in source or public docs.
    check(not re.search(rb"/home/(?:kit|admin)/|192[.]168[.]|10[.]33[.]33[.]", data), "no internal paths/network")
print(f"{checks} static source/plist guards PASS; Swift compile/runtime NOT performed")
