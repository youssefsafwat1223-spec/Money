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
# The DB-side projection. A migration INCLUDES this file rather than restating
# regexes, so the database can never drift from the canonical source by a
# transcription error the way the bundled asset did.
DB_SQL = ROOT / "supabase" / "catalog" / "generated" / "parser_rules.sql"

# ── FIELD OWNERSHIP ─────────────────────────────────────────────────────────
#
# CANONICAL-OWNED — rule configuration and identity. The canonical file is the
# only place these may be edited; both projections are generated from it and CI
# fails on divergence. A field added here MUST also be projected into the DB
# (enforced below), so a new configuration field cannot silently reach devices
# while leaving the database behind — the 0091 failure mode.
CANONICAL_IDENTITY = ["id", "bank_id"]
CANONICAL_CONFIG = [
    "sender_pattern",
    "message_pattern",
    "transaction_type",
    "language",
    "priority",
    "extracted_fields",
]

# DB-RUNTIME-OWNED — excluded by design, not by oversight:
#   is_active, is_deleted          operational state; an admin deactivates or
#                                  tombstones a rule, and the device's authority
#                                  epoch decides activation from the served
#                                  snapshot. The bundle seeds INACTIVE
#                                  regardless of what this file says.
#   created_version/updated_version/deleted_version
#                                  assigned by trg_parsers_version.
#   created_at, updated_at         database lifecycle metadata.
#   validation_status, validated_at, validated_by, golden_test_count,
#   false_positive_count, amount_error_count
#                                  evidence, written only by a parser-test run.
# Generating any of these would let a file overwrite state the database owns.
DB_RUNTIME_OWNED = [
    "is_active",
    "is_deleted",
    "created_version",
    "updated_version",
    "deleted_version",
    "created_at",
    "updated_at",
    "validation_status",
    "validated_at",
    "validated_by",
    "golden_test_count",
    "false_positive_count",
    "amount_error_count",
]

# The asset ships exactly these keys, in this order. It carries the two runtime
# flags as SEED DEFAULTS only — the seeder forces parsers inactive regardless —
# and they are never projected into the database.
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


def sql_literal(value: str) -> str:
    """Single-quoted SQL literal with quotes doubled. No E-strings: the patterns
    contain backslashes that must survive verbatim, and standard_conforming_strings
    means a plain literal is byte-exact."""
    return "'" + value.replace("'", "''") + "'"


def render_sql() -> str:
    canonical = json.loads(CANONICAL.read_text(encoding="utf-8"))
    rules = canonical["rules"]
    lines = [
        "-- GENERATED — DO NOT EDIT.",
        "--",
        "-- Source: supabase/catalog/parser_rules.json",
        "-- Regenerate: python3 tools/gen_catalog_assets.py",
        "-- Verified in CI: python3 tools/gen_catalog_assets.py --check",
        "--",
        "-- The canonical rules projected into SQL so a migration can apply them",
        "-- without restating a single regex. Migration 0091 widened the amount",
        "-- quantifier in the database and the bundled asset was never",
        "-- regenerated; the two then disagreed for months. One source, two",
        "-- generated projections, one CI check.",
        "--",
        "-- UPDATE-only and keyed by the stable parser id: this never creates or",
        "-- deletes a rule, and never touches validation evidence. Promotion",
        "-- stays the Parser Lab's job.",
        "",
    ]
    # Guard the generator against itself: a canonical config field that is not
    # projected would reach the bundle and never the database.
    projected = {
        "sender_pattern", "message_pattern", "transaction_type",
        "language", "priority", "extracted_fields",
    }
    missing = [f for f in CANONICAL_CONFIG if f not in projected]
    if missing:
        raise SystemExit(
            f"canonical config field(s) {missing} are not projected into SQL; "
            "add them to render_sql() before shipping"
        )

    for rule in rules:
        lines.append(f"-- {rule['id']}")
        lines.append("UPDATE public.sms_parsers SET")
        lines.append(f"  sender_pattern    = {sql_literal(rule['sender_pattern'])},")
        lines.append(f"  message_pattern   = {sql_literal(rule['message_pattern'])},")
        lines.append(f"  transaction_type  = {sql_literal(rule['transaction_type'])},")
        lines.append(f"  language          = {sql_literal(rule['language'])},")
        lines.append(f"  priority          = {rule['priority']},")
        lines.append(
            "  extracted_fields  = "
            f"{sql_literal(json.dumps(rule['extracted_fields'], ensure_ascii=False, sort_keys=True))}::jsonb"
        )
        # bank_id is canonical IDENTITY, not configuration: rewriting it would
        # re-point a rule at a different bank. Asserted instead, so a mismatch
        # fails loudly rather than being silently "corrected".
        lines.append(
            f"WHERE id = {sql_literal(rule['id'])}"
            f" AND bank_id = {sql_literal(rule['bank_id'])};"
        )
        lines.append("")
    # A migration that silently updates zero rows is the 0091 failure mode.
    lines += [
        "DO $$",
        "DECLARE missing INT;",
        "BEGIN",
        "  SELECT count(*) INTO missing FROM (VALUES",
    ]
    ids = ",\n".join(
        f"    ({sql_literal(r['id'])}, {sql_literal(r['bank_id'])})" for r in rules
    )
    lines.append(ids)
    lines += [
        "  ) AS want(id, bank_id)",
        "  WHERE NOT EXISTS (",
        "    SELECT 1 FROM public.sms_parsers p",
        "     WHERE p.id = want.id::uuid AND p.bank_id = want.bank_id::uuid",
        "  );",
        "  IF missing > 0 THEN",
        "    RAISE EXCEPTION",
        "      'canonical parser rules: % rule(s) absent or bound to a different bank', missing;",
        "  END IF;",
        "END $$;",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    expected = render()
    expected_sql = render_sql()
    if not args.check:
        ASSET.write_text(expected, encoding="utf-8")
        DB_SQL.parent.mkdir(parents=True, exist_ok=True)
        DB_SQL.write_text(expected_sql, encoding="utf-8")
        print(f"wrote {ASSET.relative_to(ROOT)}")
        print(f"wrote {DB_SQL.relative_to(ROOT)}")
        return 0

    actual = ASSET.read_text(encoding="utf-8") if ASSET.exists() else ""
    actual_sql = DB_SQL.read_text(encoding="utf-8") if DB_SQL.exists() else ""
    if actual_sql != expected_sql:
        print(
            "FAIL: supabase/catalog/generated/parser_rules.sql has DRIFTED from\n"
            "      the canonical source. Regenerate with:\n"
            "        python3 tools/gen_catalog_assets.py",
            file=sys.stderr,
        )
        return 1
    if actual == expected:
        print("catalog asset AND generated DB SQL are in sync with canonical")
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
