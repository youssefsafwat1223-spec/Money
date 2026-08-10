#!/usr/bin/env bash
# MALI-043 closure — deterministic SHA-256 over the iOS packaging-relevant SOURCE
# inputs. Used by BOTH tools/stamp_ios_provenance.sh (at build time) and
# app/tools/verify_ios_packaging.sh (at verify time) so a built Runner.app can be
# proven to have come from the CURRENT iOS source tree. A rename or any content
# change to a listed input flips the hash, marking a prior artifact not-current.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The provenance input set (per MALI-043 §4): Info.plist, privacy manifests,
# entitlements, the Xcode project, and the packaging/target-relevant native
# Swift — including the FORBIDDEN extension source so its reintroduction flips
# the hash. Fixed order → deterministic digest.
FILES="
app/ios/Runner/Info.plist
app/ios/Runner/PrivacyInfo.xcprivacy
app/ios/Runner/Runner.entitlements
app/ios/Runner.xcodeproj/project.pbxproj
app/ios/Runner/AppDelegate.swift
app/ios/Runner/SceneDelegate.swift
app/ios/Runner/SharedCaptureStore.swift
app/ios/ShareBankMessage/Info.plist
app/ios/ShareBankMessage/PrivacyInfo.xcprivacy
app/ios/ShareBankMessage/ShareBankMessage.entitlements
app/ios/ShareBankMessage/ShareViewController.swift
app/ios/ShareBankMessage/SharedCaptureStore.swift
app/ios/BankMessageShortcuts/BankMessageShortcuts.swift
"

{
  for f in $FILES; do
    printf 'PATH:%s\n' "$f"
    if [ -f "$f" ]; then cat "$f"; else printf '<MISSING>\n'; fi
    printf '\n---\n'
  done
} | shasum -a 256 | awk '{print $1}'
