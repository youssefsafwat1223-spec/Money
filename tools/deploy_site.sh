#!/usr/bin/env bash
# Canonical production deploy for qirsh.site.
#
# WHY THIS SCRIPT EXISTS
#
# The deploy was a raw `rsync -av --delete` copy-pasted out of the hosting docs.
# `--delete` makes the server match the build EXACTLY, and `build_site.py` emits
# app-ads.txt only when ADMOB_PUBLISHER_ID is set. So a rebuild without that one
# environment variable produced a tree with no app-ads.txt, and the next deploy
# DELETED the live file — silently breaking AdMob ad-space verification while
# reporting a completely successful sync. Nothing in the pipeline could catch it,
# because there was no pipeline: only a human remembering an env var.
#
# Every check below fails CLOSED. A deploy that cannot prove the tree is
# complete does not happen.
#
# Usage:  tools/deploy_site.sh [--allow-app-ads-change] [--preflight-only]
#
# --preflight-only runs every check and exits WITHOUT deploying. The regression
# test uses it, so the guard is proven against the real code path and can never
# reach an rsync.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# QIRSH_SITE_DIR lets the regression test point preflight at a fixture tree.
SITE="${QIRSH_SITE_DIR:-$ROOT/build/site}"
HOST="qirsh@72.62.236.204"
DOCROOT="/var/www/qirsh-site"
LIVE_URL="https://qirsh.site"
KEY="$HOME/.ssh/qirsh_vps"
ALLOW_ADS_CHANGE=0
PREFLIGHT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --allow-app-ads-change) ALLOW_ADS_CHANGE=1 ;;
    --preflight-only)       PREFLIGHT_ONLY=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "DEPLOY REFUSED: $*" >&2; exit 1; }
ok()  { echo "  ok  $*"; }

echo "== preflight =="

# 1) The tree must exist and look like a built site.
[ -d "$SITE" ] || die "no build tree at build/site — run: python3 tools/build_site.py"
[ -s "$SITE/index.html" ] || die "build/site/index.html missing or empty"
ok "build tree present"

# 2) Every route that must never vanish from production. --delete removes
#    anything absent here, so an incomplete build is a silent outage.
REQUIRED_FILES=(
  "index.html" "privacy/index.html" "terms/index.html" "support/index.html"
  "en/index.html" "en/privacy/index.html" "en/terms/index.html" "en/support/index.html"
  "app-ads.txt"
)
for f in "${REQUIRED_FILES[@]}"; do
  [ -s "$SITE/$f" ] || die "required file missing or empty: $f
       A --delete deploy would REMOVE it from production."
done
ok "all ${#REQUIRED_FILES[@]} required files present and non-empty"

# 3) app-ads.txt shape. A wrong publisher id authorises the wrong seller, which
#    is worse than having no file, so the shape is checked rather than assumed.
ADS="$SITE/app-ads.txt"
LINES=$(grep -c . "$ADS" || true)
[ "$LINES" = "1" ] || die "app-ads.txt must contain exactly 1 non-empty line, found $LINES"
grep -Eq '^google\.com, pub-[0-9]{16}, DIRECT, f08c47fec0942fa0$' "$ADS" \
  || die "app-ads.txt does not match the required contract:
       google.com, pub-<16 digits>, DIRECT, f08c47fec0942fa0"
grep -Eqi 'XXXX|placeholder|TODO' "$ADS" && die "app-ads.txt contains a placeholder"
ok "app-ads.txt shape valid"

# 4) If the publisher id is supplied, the file must actually match it. No id is
#    hardcoded here — it comes from the environment or from what is already live.
if [ -n "${ADMOB_PUBLISHER_ID:-}" ]; then
  grep -Fq "google.com, ${ADMOB_PUBLISHER_ID}, DIRECT, f08c47fec0942fa0" "$ADS" \
    || die "app-ads.txt does not match ADMOB_PUBLISHER_ID"
  ok "app-ads.txt matches ADMOB_PUBLISHER_ID"
fi

# 5) Preserve what is already live. Fetching the live file needs no stored
#    secret and directly enforces "do not change app-ads.txt by accident": a
#    deliberate change requires --allow-app-ads-change.
if LIVE_ADS=$(curl -sS -m 20 "$LIVE_URL/app-ads.txt" 2>/dev/null) && [ -n "$LIVE_ADS" ]; then
  if [ "$LIVE_ADS" != "$(cat "$ADS")" ]; then
    [ "$ALLOW_ADS_CHANGE" = "1" ] \
      || die "app-ads.txt differs from the live file.
       If this change is intended, re-run with --allow-app-ads-change."
    echo "  !!  app-ads.txt differs from live — proceeding under --allow-app-ads-change"
  else
    ok "app-ads.txt identical to the live file"
  fi
else
  echo "  --  live app-ads.txt unreachable; shape checks above still applied"
fi

if [ "$PREFLIGHT_ONLY" = "1" ]; then
  echo "PREFLIGHT OK (--preflight-only: nothing deployed)"
  exit 0
fi

echo "== deploying =="
rsync -av --delete --rsync-path="sudo rsync" -e "ssh -i $KEY -o BatchMode=yes" \
  "$SITE/" "$HOST:$DOCROOT/"
ssh -i "$KEY" -o BatchMode=yes "$HOST" "sudo chown -R www-data:www-data $DOCROOT"

echo "== post-deploy verification =="
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -m 20 "$LIVE_URL/app-ads.txt")
[ "$CODE" = "200" ] || die "POST-DEPLOY: app-ads.txt returned HTTP $CODE"
[ "$(curl -sS -m 20 "$LIVE_URL/app-ads.txt")" = "$(cat "$ADS")" ] \
  || die "POST-DEPLOY: live app-ads.txt does not match what was deployed"
ok "live app-ads.txt verified"
echo "DEPLOY OK"
