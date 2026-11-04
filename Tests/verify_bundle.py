"""macOS artifact gate, not a provisioning or device-acceptance test."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path

def verify(app):
    extension = app / "PlugIns/Broadcast.appex"
    assert extension.is_dir(), "broadcast extension missing"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    ext_info = plistlib.loads((extension / "Info.plist").read_bytes())
    assert info["CFBundleVersion"] == ext_info["CFBundleVersion"] == "2"
    assert info["MinimumOSVersion"] == ext_info["MinimumOSVersion"] == "27.0"
    assert info["DTSDKName"] == "iphoneos27.2"
    assert ext_info["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".broadcast"
    assert "audio" in info["UIBackgroundModes"]
    assert info["SharedAppGroupCandidates"] == ext_info["SharedAppGroupCandidates"]
    point = ext_info["NSExtension"]
    assert point["NSExtensionPointIdentifier"] == "com.apple.broadcast-services-upload"
    assert point["NSExtensionPrincipalClass"] == "Broadcast.SampleHandler"
    assert point["RPBroadcastProcessMode"] == "RPBroadcastProcessModeSampleBuffer"
    assert (app / "Assets.car").stat().st_size > 0, "compiled asset catalog missing"
    icon = info["CFBundleIcons"]["CFBundlePrimaryIcon"]
    assert icon["CFBundleIconName"] == "AppIcon", "AppIcon not selected"
    files = icon["CFBundleIconFiles"]
    assert files and any(app.glob("AppIcon*.png")), "compiled icon resources missing"
    for prefix in files:
        assert any(app.glob(prefix + "*.png")), "declared icon resource missing"
    claims = {}
    for bundle in [extension, app]:
        assert (bundle / plistlib.loads((bundle / "Info.plist").read_bytes())["CFBundleExecutable"]).is_file()
        subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
        result = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(bundle)],
                                check=True, capture_output=True)
        entitlements = plistlib.loads(result.stdout)
        assert entitlements["com.apple.security.application-groups"] == ["group.com.aian.livesubs"]
        assert "keychain-access-groups" not in entitlements
        assert b"$(" not in result.stdout, "unexpanded signing variable"
        claims[bundle.name] = entitlements
    return {"build": info["CFBundleVersion"], "sdk": info["DTSDKName"],
            "minimumOS": info["MinimumOSVersion"], "extension": ext_info["CFBundleIdentifier"],
            "icon": icon, "assetsBytes": (app / "Assets.car").stat().st_size,
            "embeddedEntitlements": claims,
            "adHocMetadataOnly": True, "personalSigningVerified": False, "deviceVerified": False}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = verify(args.app)
    encoded = json.dumps(report, indent=2)
    if args.output:
        args.output.write_text(encoded + "\n")
    print(encoded)
