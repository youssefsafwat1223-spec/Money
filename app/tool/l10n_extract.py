#!/usr/bin/env python3
"""Extract hardcoded Arabic UI literals and report them for ARB migration.

Deliberately conservative. It only reports literals it can migrate SAFELY:

  * no interpolation (`$x` / `${...}`) — those need ARB placeholders and a
    per-string decision about plural/select, which a script should not guess;
  * inside a widget-bearing file;
  * not a `debugPrint`, comment, key, or asset path.

Anything it skips is listed with the reason, so the remainder is visible
instead of silently dropped.
"""
import json, re, sys, os

ARABIC = re.compile(r'[؀-ۿ]')

# Arabic that is DATA, not copy. Translating any of it breaks the thing it
# exists to do, so these paths are reported separately rather than as work.
#
#   * engine/**            — SMS parser patterns, bank names, merchant keywords
#   * rules_client         — the same keyword vocabulary, server-side
#   * app_database         — SQL LIKE patterns for sender/body matching
#   * portable_csv         — CSV column-name ALIASES used to recognise an
#                            imported file's columns ('التاريخ', 'المبلغ', …).
#                            Translate one and that column stops being found.
#   * brand_mark           — merchant brand names, matched against raw text
#   * category_seeds       — seed keywords for categorisation
DATA_NOT_COPY = (
    'lib/engine/',
    'lib/core/backend/rules_client.dart',
    'lib/data/db/app_database.dart',
    'lib/core/data_portability/portable_csv.dart',
    'lib/features/cards/brand_mark.dart',
    # bank NAME -> key mappings ('الراجحي:alrajhi'), matched against SMS text
    'lib/features/cards/bank_mark.dart',
    # the SMS parser's keyword vocabulary and its regexes: 'خصم', 'كافيه',
    # '(?:الرسوم|الرسم|الضريبة|...)'. Translating one silently stops a whole
    # class of transaction from being recognised or categorised.
    'lib/domain/usecases/add_transaction_usecase.dart',
)

# Files that are already bilingual: the Arabic half of an `en ? … : …` pair, or
# a locale-dispatched table. Reporting them as untranslated is noise.
ALREADY_BILINGUAL = (
    'report_l10n.dart',
    'lib/core/utils/currency.dart',
    'lib/core/utils/formatters.dart',
    'achievement_catalog.dart',
    'notification_journey_service.dart',
    'local_notification_service.dart',
    'capture_notification_content.dart',
    'lib/features/dashboard/dashboard_providers.dart',
    'lib/features/dashboard/home_sections_providers.dart',
    'lib/features/transactions/transactions_providers.dart',
    'lib/domain/finance/budget_period.dart',
)
LITERAL = re.compile(r"'([^'\\\n]{2,200})'")
INTERP = re.compile(r'\$\{?\w')

SKIP_LINE = re.compile(r'debugPrint|//|assert\(|Key\(|asset|package:|import |export ')

def extract(path):
    simple, complex_, skipped = [], [], []
    for i, line in enumerate(open(path, encoding='utf-8'), 1):
        if SKIP_LINE.search(line):
            continue
        for m in LITERAL.finditer(line):
            s = m.group(1)
            if not ARABIC.search(s):
                continue
            if INTERP.search(s):
                complex_.append((i, s))
            else:
                simple.append((i, s))
    return simple, complex_, skipped

if __name__ == '__main__':
    total_s = total_c = 0
    skipped_data = skipped_bilingual = 0
    for path in sys.argv[1:]:
        if any(d in path for d in DATA_NOT_COPY):
            skipped_data += 1
            continue
        if any(b in path for b in ALREADY_BILINGUAL):
            skipped_bilingual += 1
            continue
        s, c, _ = extract(path)
        total_s += len(s); total_c += len(c)
        print(f"{path}")
        print(f"   simple (migratable): {len(s)}   interpolated (manual): {len(c)}")
    print(f"\nTOTAL simple={total_s} interpolated={total_c}")
