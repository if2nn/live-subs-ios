"""Isolated iOS 27 UI gate. Never reads credentials; creates a fresh simulator."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "simulator-artifacts"
STATE = OUT / "simulator.json"

def run(args, check=True, timeout=120):
    print("+ " + " ".join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str, args)), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=timeout)
    print(result.stdout, flush=True)
    if check and result.returncode:
        raise RuntimeError(f"Command exited {result.returncode}")
    return result

def simjson(kind):
    return json.loads(run(["xcrun", "simctl", "list", kind, "--json"]).stdout)[kind]

def collect():
    OUT.mkdir(exist_ok=True)
    if not STATE.exists():
        (OUT / "collection-note.txt").write_text("Setup failed before device creation. See runner.log.")
        return
    state = json.loads(STATE.read_text())
    udid = state["udid"]
    def best(args, name):
        try:
            result = run(args, check=False, timeout=60)
            (OUT / name).write_text(result.stdout)
        except Exception as error:
            (OUT / name).write_text(str(error))
    best(["xcrun", "simctl", "io", udid, "screenshot", "--display=1", OUT / "final-screen.png"], "screenshot.log")
    best(["xcrun", "simctl", "spawn", udid, "log", "show", "--style", "compact",
          "--start", state["started"], "--predicate",
          'process == "LiveSubs" OR process == "Broadcast"'], "app-unified.log")
    try:
        result = run(["xcrun", "simctl", "get_app_container", udid, "com.aian.livesubs", "data"], check=False)
        container = Path(result.stdout.strip())
        if result.returncode == 0 and (container / "Documents").is_dir():
            dest = OUT / "Documents-diagnostics"
            dest.mkdir(exist_ok=True)
            for file in (container / "Documents").rglob("*"):
                if file.is_file() and ("diagnostic" in file.name.lower() or file.suffix == ".log"
                                       or (file.name.startswith("caption-frame-") and file.suffix == ".png")):
                    target = dest / file.relative_to(container / "Documents")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(file, target)
    except Exception as error:
        (OUT / "documents-error.txt").write_text(str(error))
    crashes = OUT / "crashes"
    crashes.mkdir(exist_ok=True)
    roots = [Path.home() / "Library/Logs/DiagnosticReports",
             Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data/Library/Logs/CrashReporter"]
    count = 0
    for base in roots:
        if not base.exists():
            continue
        for file in base.rglob("*"):
            if file.suffix not in {".ips", ".crash"} or not file.is_file():
                continue
            if not any(file.name.startswith(prefix) for prefix in ("LiveSubs-", "LiveSubs_", "Broadcast-", "Broadcast_")):
                continue
            if file.stat().st_mtime < state["epoch"]:
                continue
            count += 1
            shutil.copy2(file, crashes / f"{count}-{file.name}")
    (OUT / "crash-summary.json").write_text(json.dumps({"target_app_reports": count}))
    if count:
        raise RuntimeError("Target app crash report found")
    required = [OUT / "UITests.xcresult", OUT / "final-screen.png",
                OUT / "Documents-diagnostics/diagnostics.log"]
    if not all(path.exists() for path in required):
        raise RuntimeError("Required simulator evidence missing")
    frames = sorted((OUT / "Documents-diagnostics").glob("caption-frame-*.png"))
    if not frames:
        raise RuntimeError("Required caption frame evidence missing")
    (OUT / "caption-frames.txt").write_text("\n".join(f.name for f in frames) + "\n")

def test():
    OUT.mkdir(exist_ok=True)
    epoch = datetime.datetime.now().timestamp()
    run(["xcodebuild", "-version"])
    run(["xcodebuild", "-showsdks"])
    run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
    runtimes = [r for r in simjson("runtimes") if r.get("isAvailable") and
                r.get("version", "").split(".")[0] == "27" and ".iOS-" in r["identifier"]]
    if not runtimes:
        raise RuntimeError("No available iOS 27 runtime; release gate blocked")
    runtime = sorted(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))[-1]
    devices = simjson("devices").get(runtime["identifier"], [])
    types = simjson("devicetypes")
    available = [d for d in devices if d.get("isAvailable") and d.get("name", "").startswith("iPhone")]
    type_id = available[0].get("deviceTypeIdentifier") if available else None
    if not type_id:
        candidates = [d for d in types if d.get("productFamily") == "iPhone" or d["name"].startswith("iPhone")]
        if not candidates:
            raise RuntimeError("No installed iPhone device type")
        type_id = candidates[-1]["identifier"]
    # Never reuse a simulator with pre-existing credentials.
    udid = run(["xcrun", "simctl", "create", "LiveSubs-UI-Gate", type_id, runtime["identifier"]]).stdout.strip()
    state = {"udid": udid, "runtime": runtime, "deviceType": type_id,
             "epoch": epoch, "started": datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S")}
    STATE.write_text(json.dumps(state, indent=2))
    print(STATE.read_text(), flush=True)
    run(["xcrun", "simctl", "boot", udid])
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=240)
    # bootstatus is the readiness gate; do not block tests on a redundant global device inventory.
    ent = OUT / "Simulator.entitlements"
    ent.write_bytes(plistlib.dumps({}))
    result = run(["xcodebuild", "-project", "LiveSubs.xcodeproj", "-scheme", "LiveSubs",
                  "-configuration", "Debug", "-sdk", "iphonesimulator",
                  "-destination", f"platform=iOS Simulator,id={udid}",
                  "-derivedDataPath", "simulator-build", "-resultBundlePath", str(OUT / "UITests.xcresult"),
                  "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                  "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
                  f"CODE_SIGN_ENTITLEMENTS={ent}", "test"], check=False, timeout=1500)
    (OUT / "xcodebuild.log").write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"Simulator UI tests failed ({result.returncode})")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--collect", action="store_true")
    args = parser.parse_args()
    try:
        collect() if args.collect else test()
    except Exception as error:
        print(f"GATE FAILED: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
