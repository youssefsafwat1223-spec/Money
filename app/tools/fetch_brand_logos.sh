#!/usr/bin/env bash
#
# Fetches brand logos from Simple Icons (https://simpleicons.org) into
# assets/brands/. The Simple Icons set is CC0; the brand trademarks themselves
# remain the property of their owners — use responsibly.
#
# Run from the app/ directory:
#   bash tools/fetch_brand_logos.sh
#
# After it runs, add each downloaded slug to `_brandSvgs` in
# lib/features/cards/brand_mark.dart (uppercase merchant keyword -> slug), e.g.
#   'STARBUCKS': 'starbucks',
#
set -uo pipefail

DEST="assets/brands"
mkdir -p "$DEST"

# Simple Icons slugs (lowercase). Add/remove freely. Regional merchants that
# aren't on Simple Icons will print ✗ and be skipped — use the admin logo_url
# (network) path for those instead.
slugs=(
  netflix spotify youtube apple amazon
  starbucks mcdonalds kfc hardees
  ubereats uber deliveroo airbnb
  carrefour ikea noon talabat
  vodafone orange etisalat
  anghami shahid
)

ok=0; fail=0
for slug in "${slugs[@]}"; do
  if curl -fsSL "https://cdn.simpleicons.org/${slug}" -o "$DEST/${slug}.svg"; then
    echo "✓ $slug"
    ok=$((ok+1))
  else
    rm -f "$DEST/${slug}.svg"
    echo "✗ $slug (not on Simple Icons — use admin logo_url instead)"
    fail=$((fail+1))
  fi
done

echo
echo "Done: $ok downloaded, $fail skipped → $DEST"
echo "Next: map the downloaded slugs in lib/features/cards/brand_mark.dart (_brandSvgs)."
