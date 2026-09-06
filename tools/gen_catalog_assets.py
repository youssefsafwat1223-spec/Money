#!/usr/bin/env python3
"""Generate app/assets/catalog/parsers.json from the canonical rule source.

WHY THIS EXISTS
The bundled asset was hand-maintained. Migration 0091 widened the amount
quantifier from {1,2} to {1,3} in the database and nobody regenerated the
asset, so all twelve shipped rules kept the pre-0091 shape. Because
catalog-delta serves no parsers (none are validated), that fix could not reach
a device by any route. One canonical file plus a CI drift check makes the two
copies incapable of diverging silently again.

Usage:
  python3 tools/gen_catalog_assets.py           # write the asset
  python3 tools/gen_catalog_assets.py --check   # exit 1 if the asset is stale
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CANONICAL = ROOT / "supabase" / "catalog" / "parser_rules.json"
ASSET = ROOT / "app" / "assets" / "catalog" / "parsers.json"

# The asset ships exactly these keys, in this order. Anything the canonical file
# carries for provenance (comments) stays out of the shipped bundle.
ASSET_KEYS = [
    "id",
    "bank_id",
    "sender_pattern",
    "message_pattern",
    "transaction_type",
    "language",
    "priority",
    "extracted_fields",
    "is_active",
    "is_deleted",
    "updated_at",
]


def render() -> str:
    canonical = json.loads(CANONICAL.read_text(encoding="utf-8"))
    rules = canonical["rules"]
    shaped = [{k: rule[k] for k in ASSET_KEYS if k in rule} for rule in rules]
    return json.dumps(shaped, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    expected = render()
    if not args.check:
        ASSET.write_text(expected, encoding="utf-8")
        print(f"wrote {ASSET.relative_to(ROOT)}")
        return 0

    actual = ASSET.read_text(encoding="utf-8") if ASSET.exists() else ""
    if actual == expected:
        print("catalog asset is in sync with supabase/catalog/parser_rules.json")
        return 0

    print(
        "FAIL: app/assets/catalog/parsers.json has DRIFTED from the canonical\n"
        "      source supabase/catalog/parser_rules.json.\n"
        "      Regenerate with: python3 tools/gen_catalog_assets.py\n"
        "      Never hand-edit the asset — that is how the 0091 fix was lost.",
        file=sys.stderr,
    )
    # Show which rule ids differ, without dumping whole regexes into CI logs.
    try:
        want = {r["id"]: r for r in json.loads(expected)}
        have = {r["id"]: r for r in json.loads(actual)} if actual else {}
    except json.JSONDecodeError:
        return 1
    for rid in sorted(set(want) | set(have)):
        if rid not in have:
            print(f"      missing from asset: {rid}", file=sys.stderr)
        elif rid not in want:
            print(f"      unexpected in asset: {rid}", file=sys.stderr)
        else:
            for key in ASSET_KEYS:
                if want[rid].get(key) != have[rid].get(key):
                    print(f"      {rid}: field '{key}' differs", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
