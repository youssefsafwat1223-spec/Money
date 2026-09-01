"""Extract the shipping catalog parser rules into the benchmark's input.

## Why this is a file rather than a one-off command

D3 corroboration is only meaningful if the rules the benchmark sees are the
rules the phone would have. That makes `data/catalog_rules.json` a CONTRACT
ARTEFACT: its contents decide whether a direction is corroborated, and
therefore whether a message may auto-commit. A contract artefact produced by an
untracked shell command cannot be audited — nobody can tell later whether the
file still corresponds to the migration it claims to come from.

So the supply chain is: the migration is the source of truth, this script is the
only thing that reads it, and the Phase-4 seal hashes all three (migration,
script, output). `--check` re-runs the extraction and asserts the result is
byte-identical to what is on disk, which is what makes the seal's hash mean
"this really came from that migration" rather than "someone wrote a file".

## What is extracted

Active, non-deleted rows from the `$catalog_parsers$` seed in
`0002_catalog_mvp.sql`. Nothing is rewritten, reordered or normalised: the
regexes and `extracted_fields` are carried across verbatim, because a benchmark
that "tidies" a production rule is no longer measuring production.

    python3 tools/extract_catalog_rules.py           # write
    python3 tools/extract_catalog_rules.py --check    # verify byte-identical
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
ROOT = LAB.parent.parent
MIGRATION = ROOT / "supabase" / "migrations" / "0002_catalog_mvp.sql"
OUT = LAB / "data" / "catalog_rules.json"

_SEED = re.compile(r"\$catalog_parsers\$(\[.*?\])\$catalog_parsers\$", re.S)


def build() -> str:
    sql = MIGRATION.read_text(encoding="utf-8")
    m = _SEED.search(sql)
    if not m:
        raise SystemExit(f"no $catalog_parsers$ seed found in {MIGRATION}")
    rules = json.loads(m.group(1))
    active = [
        {
            "id": r["id"],
            "sender_pattern": r["sender_pattern"],
            "message_pattern": r["message_pattern"],
            "transaction_type": r["transaction_type"],
            "priority": r["priority"],
            "extracted_fields": r["extracted_fields"],
        }
        for r in rules
        if r.get("is_active") and not r.get("is_deleted")
    ]
    # Sorted by id so the output is a pure function of the seed's CONTENT and
    # not of the order rows happen to appear in the migration.
    active.sort(key=lambda r: r["id"])
    return json.dumps(
        {
            "_source": "supabase/migrations/0002_catalog_mvp.sql "
                       "$catalog_parsers$ seed",
            "_generator": "research/sms_model_lab/tools/extract_catalog_rules.py",
            "_why": "The shipping app syncs these from `sms_parsers` into local "
                    "Drift, so a benchmark passing `catalogRules: []` would "
                    "disable D3 — a corroborator the phone genuinely has — and "
                    "then report the result as the shipping architecture.",
            "_selection": "is_active AND NOT is_deleted, sorted by id",
            "_verbatim": "patterns and extracted_fields are copied unchanged; "
                         "normalising them would stop this being production",
            "active_rule_count": len(active),
            "rules": active,
        },
        indent=2,
        ensure_ascii=False,
    ) + "\n"


def main() -> None:
    content = build()
    if "--check" in sys.argv:
        if not OUT.exists():
            print(f"MISSING: {OUT}")
            sys.exit(1)
        on_disk = OUT.read_text(encoding="utf-8")
        if on_disk != content:
            print("DRIFT: catalog_rules.json does not match the migration.")
            print("The benchmark would be consuming rules the app does not ship.")
            sys.exit(1)
        n = json.loads(on_disk)["active_rule_count"]
        print(f"OK: byte-identical regeneration, {n} active rules")
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(content, encoding="utf-8")
    print(f"wrote {json.loads(content)['active_rule_count']} active rules -> {OUT}")


if __name__ == "__main__":
    main()
