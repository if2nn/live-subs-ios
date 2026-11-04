"""Contract/privacy guards plus execution of the exact shipped Swift state policy.
Missing Swift is a failure, never reported as behavioral PASS."""
from pathlib import Path
import shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
ipc = (root / "Shared/CaptureIPC.swift").read_text()
handler = (root / "Broadcast/SampleHandler.swift").read_text()
socket = (root / "Shared/Soniox.swift").read_text()
assert "CaptureState.status(s,now:now,sharedAvailable:sharedAvailable)" in ipc
assert handler.index("CaptureIPC.extensionEntered()") < handler.index("let keyResult")
assert "private lazy var client = Soniox()" in handler
assert handler.index("CaptureIPC.audio(frames:") < handler.index("autoreleasepool { convert")
assert "snapshot.audioAppBuffers &+= 1" in ipc
audio = ipc.split("func audio(_ frames: Int)")[1].split("func tokens(")[0]
assert "flush(" not in audio and "write(" not in audio and ".async" not in audio, "no IO per audio buffer"
sent = ipc.split("func audioSent(_ bytes: Int)")[1].split("func audioDropped(")[0]
assert "if first {" in sent, "only the first sent chunk flushes"
assert "value.schema == 2" in ipc
assert "events.count > 96" in ipc and "65_536" in ipc
assert ".atomic" in ipc and "fsync(fd)" in ipc and "task_info(" in ipc
assert "error_message" not in socket and "localizedDescription" not in socket
assert "self.onEvent?(.configSent" in socket
assert "self.authenticated=true;self.onEvent?(.protocolConfirmed" in socket
assert "didOpenWithProtocol" in socket
assert "Authorization" in socket and '"api_key"' not in socket
for name in ["diagnosticText", "exportLogText", "statusText"]:
    assert f"static var {name}: String" in ipc
swift = shutil.which("swiftc")
if not swift:
    raise SystemExit("Swift compiler unavailable; behavioral test NOT RUN. Run in macOS CI.")
with tempfile.TemporaryDirectory() as tmp:
    exe = Path(tmp) / "capture-tests"
    subprocess.run([swift, "-swift-version", "6", str(root / "Shared/CaptureState.swift"),
                    str(root / "Tests/CaptureStateTests.swift"), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print("Capture IPC source guards + compiled behavior tests PASS")
