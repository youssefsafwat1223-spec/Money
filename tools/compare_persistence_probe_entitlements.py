#!/usr/bin/env python3
"""TEMP-PROBE: fail-closed comparison of two SIGNED Runner.app bundles.

Read-only: no signing, profile changes, installation or upload. Preserve list
order because the first keychain group determines the default storage namespace.
"""
import json
import pathlib
import plistlib
import subprocess
import sys


def inspect(root, extension):
    bundle = root / "PlugIns/ShareBankMessage.appex" if extension else root
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(bundle)],
        capture_output=True, check=True,
    )
    entitlements = plistlib.loads(result.stdout)
    with (bundle / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected_bundle = "com.youssefsafwat.mali" + (".ShareBankMessage" if extension else "")
    assert info["CFBundleIdentifier"] == expected_bundle, "wrong bundle namespace"
    assert entitlements["application-identifier"] == "5TWARK8A23." + expected_bundle
    assert entitlements["com.apple.developer.team-identifier"] == "5TWARK8A23"
    assert entitlements.get("get-task-allow") is False, "debug entitlement forbidden"
    if not extension:
        assert entitlements.get("aps-environment") == "production", "wrong APNs environment"
    assert entitlements.get("beta-reports-active") is True, "not App Store distribution"
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)],
                   capture_output=True, check=True)
    return entitlements


def main():
    if len(sys.argv) != 3:
        raise ValueError("usage: compare_persistence_probe_entitlements.py BASELINE_RUNNER_APP CANDIDATE_RUNNER_APP")
    baseline, candidate = map(pathlib.Path, sys.argv[1:])
    reference = json.loads(baseline.read_text()) if baseline.suffix == '.json' else None
    different = False
    for extension, target in [(False, "Runner"), (True, "ShareBankMessage")]:
        original = reference[target] if reference is not None else inspect(baseline, extension)
        diagnostic = inspect(candidate, extension)
        diff = {key: {"baseline": original.get(key), "candidate": diagnostic.get(key)}
                for key in sorted(original.keys() | diagnostic.keys())
                if original.get(key) != diagnostic.get(key) or
                (key in original) != (key in diagnostic)}
        print(json.dumps({"target": target, "entitlementDiff": diff}, sort_keys=True))
        different |= bool(diff)
    return 1 if different else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, AssertionError, subprocess.CalledProcessError) as error:
        # Do not dump codesign stdout/stderr or arbitrary file contents on failure.
        print(f"STOP: entitlement comparison unavailable/invalid ({type(error).__name__}).", file=sys.stderr)
        sys.exit(2)
