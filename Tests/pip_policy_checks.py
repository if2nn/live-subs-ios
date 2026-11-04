"""Run real Swift policy tests. No Python mirror and no source grep."""
from pathlib import Path
import shutil
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
compiler = shutil.which("swiftc")
if not compiler:
    raise SystemExit("swiftc unavailable: policy execution NOT performed (run in macOS CI)")
with tempfile.TemporaryDirectory() as directory:
    binary = str(Path(directory) / "pip-policy-tests")
    subprocess.run([compiler, "-swift-version", "6", str(root / "Shared/PiPPolicy.swift"),
                    str(root / "Tests/PiPPolicyTests.swift"), "-o", binary], check=True)
    subprocess.run([binary], check=True)
