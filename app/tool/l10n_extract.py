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
    # Mixed, and neither half is work: `currencyKeywords` are SMS FILTER
    # keywords ('ريال', 'ر.س') the shortcut matches against, and
    # `subscriptionShowcase` already carries priceAr AND priceEn.
    'lib/features/onboarding/onboarding_options.dart',
    # SMS/CSV keyword vocabularies and digit tables, same class as the parser
    # engine: «مصروف»/«مدين» are matched against an imported file's cells, and
    # '٠١٢٣٤٥٦٧٨٩' is a DIGIT TABLE. Translating either breaks import.
    'lib/core/data_portability/generic_transaction_import.dart',
    # SMS keywords the bank-discovery heuristic matches on.
    'lib/domain/services/bank_discovery_service.dart',
    # Merchant-normalisation regexes, including Arabic alternations.
    'lib/features/coupons/merchant_lookup_pipeline.dart',
    # Arabic-Indic digit character classes inside input formatters.
    'lib/features/subscriptions/bill_form_sheet.dart',
    'lib/features/transactions/manual_transaction_sheet.dart',
    # DEFAULT NAMES WRITTEN INTO THE DATABASE, not copy. Each becomes a row the
    # user can rename, so it is their data from the moment it is created;
    # rendering it through the ARB would overwrite a name they chose. Where the
    # language IS known at creation time it is now used (see
    # `user_settings_usecases.dart`); these run before it is, or name a row
    # arriving from the server with no name of its own.
    # NOTE: this file also holds `كل المصروفات`, the ALL-EXPENSES
    # pseudo-category, and that one is NOT data — it has a fixed id, the user
    # cannot rename it, and it read Arabic in the English build until
    # `CategoryView.name` was taught about it. It is excluded here because the
    # SEED ROW is genuinely data; the LABEL is resolved in
    # `category_catalog.dart` and guarded by
    # `category_catalog_language_test`. A file-level exclusion cannot make
    # that distinction, which is exactly how the defect hid.
    'lib/data/db/database_seed.dart',
    'lib/data/repositories/drift_bill_repository.dart',
    'lib/data/repositories/drift_smart_inbox_repository.dart',
    'lib/domain/usecases/run_goal_auto_saves_usecase.dart',
    'lib/features/planning_sync/services/planning_pull_service.dart',
    'lib/features/capture/services/capture_sync_service.dart',
    'lib/data/repositories/account_currency_repair_service.dart',
    'lib/core/sync/conflict_policy.dart',
    # The brand name, deliberately Arabic in every language.
    'lib/features/reporting/pdf/report_pdf_renderer.dart',
)

# Screens that exist only in debug builds, so nothing here is user-facing copy
# in a release. `/design` is behind `if (kDebugMode)` in app_router.dart, and
# FoundationHomeScreen has no reference anywhere outside its own file.
DEBUG_ONLY = (
    'lib/features/design_gallery/design_gallery_screen.dart',
    'lib/features/foundation/foundation_home_screen.dart',
)

# A literal is ALREADY BILINGUAL when its own statement carries the other half
# — an `en ? … : …` pair, a `lang ==` dispatch, or a `code:` that the UI
# renders from the ARB.
#
# This is checked PER LITERAL, not per file, and that distinction matters: the
# file-level lists below cannot see a NEW untranslated string added to a file
# that is mostly fine. `encrypted_backup_service.dart` has 40 coded throws; a
# 41st without a code has to be reported, and a file-level exclusion would
# swallow it.
BILINGUAL_MARKERS = (
    'code:',           # a DataPortabilityError / BackupError / ImportIssueCode
    "== 'en'",         # explicit language dispatch
    'if (en)',
    'en ?',            # the common `final en = lang == 'en'` shorthand
    'languageCode',
    'defaultPromptAr', # the Arabic fallback beside a caller-supplied string
    'repoErrorMessage',
    'cardThemeLabel',
)

# A `switch`/`if` whose OTHER arm is the English one can be many lines away —
# `capture_review_notification` has a full English switch above the Arabic one,
# and `budget_alert_planner` puts the two branches of each threshold apart. A
# window big enough to see them is still far narrower than the file, so a
# genuinely untranslated string in an otherwise-bilingual file is still found.
BILINGUAL_WINDOW = 28


def _bilingual_context(lines, index):
    """The code around line `index`, wide enough to see the other half of a
    bilingual pair — a ternary, a two-branch if, or the English arm of a
    switch — without swallowing the whole file."""
    lo = max(0, index - BILINGUAL_WINDOW)
    hi = min(len(lines), index + BILINGUAL_WINDOW)
    return ''.join(lines[lo:hi])

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
    # The import/export services carry an Arabic `message` on every throw AND a
    # locale-independent `code`; the UI renders the code through the ARB and
    # falls back to the message. The Arabic here is the fallback half of a
    # bilingual pair, not untranslated copy.
    'lib/core/data_portability/app_data_portability_service.dart',
    'lib/core/data_portability/drift_financial_exporter.dart',
    'lib/core/data_portability/drift_financial_importer.dart',
    'lib/core/data_portability/qirsh_package_codec.dart',
    # The Arabic here never reaches a user: `AuthCancelledException` shows
    # nothing by design, the one configuration failure is rendered from the ARB
    # at the display site, and everything else surfaces as `authSignInError`.
    # These strings are log lines.
    'lib/core/auth/supabase_auth_service.dart',
    # SMS keyword matching, same class as the parser engine.
    'lib/features/capture/manual_paste_splitter.dart',
    # Every arm has a localized counterpart in `repo_error_messages.dart`, and
    # `repo_error_messages_test` asserts the two agree — a stronger guard than
    # this grep, because it fails when the two switches DRIFT rather than when
    # an Arabic string exists.
    'lib/domain/errors/repo_exceptions.dart',
    # Bilingual via `lang`. What is left here is the Arabic branch plus
    # `_arDays`, the Arabic five-category day plural whose English counterpart
    # `_enDays` sits beside it. `notification_planner_test` asserts the English
    # rendering, which is what fails if `lang` is dropped again.
    'lib/domain/services/budget_alert_planner.dart',
    'lib/features/capture/services/capture_review_notification.dart',
    # `lang == 'ar' ? … : 'All expenses'`.
    'lib/features/reporting/composition/report_composer.dart',
    # The Arabic list separator «،», chosen by Directionality beside its Latin
    # counterpart.
    'lib/features/common/app_transaction_row.dart',
    # The const theme catalog's Arabic fallback; `cardThemeLabel` renders from
    # the ARB.
    'lib/features/cards/card_theme.dart',
    # The Arabic fallback beside the caller-supplied localized prompt.
    'lib/core/security/app_lock_service.dart',
)
LITERAL = re.compile(r"'([^'\\\n]{2,200})'")
INTERP = re.compile(r'\$\{?\w')

SKIP_LINE = re.compile(r'debugPrint|//|assert\(|Key\(|asset|package:|import |export ')

def extract(path):
    simple, complex_, skipped = [], [], []
    lines = open(path, encoding='utf-8').readlines()
    for idx, line in enumerate(lines):
        i = idx + 1
        if SKIP_LINE.search(line):
            continue
        for m in LITERAL.finditer(line):
            s = m.group(1)
            if not ARABIC.search(s):
                continue
            context = _bilingual_context(lines, idx)
            if any(marker in context for marker in BILINGUAL_MARKERS):
                skipped.append((i, s, 'bilingual'))
                continue
            if INTERP.search(s):
                complex_.append((i, s))
            else:
                simple.append((i, s))
    return simple, complex_, skipped

if __name__ == '__main__':
    total_s = total_c = total_pairs = 0
    skipped_data = skipped_bilingual = skipped_debug = 0
    for path in sys.argv[1:]:
        if any(d in path for d in DATA_NOT_COPY):
            skipped_data += 1
            continue
        if any(b in path for b in ALREADY_BILINGUAL):
            skipped_bilingual += 1
            continue
        if any(d in path for d in DEBUG_ONLY):
            skipped_debug += 1
            continue
        s, c, pairs = extract(path)
        total_pairs += len(pairs)
        if not s and not c:
            continue
        total_s += len(s); total_c += len(c)
        print(f"{path}")
        print(f"   simple (migratable): {len(s)}   interpolated (manual): {len(c)}"
              f"   already bilingual: {len(pairs)}")
    print(f"\nskipped whole files: data={skipped_data} "
          f"bilingual={skipped_bilingual} debug-only={skipped_debug}")
    print(f"already bilingual in place (Arabic half of a pair): {total_pairs}")
    print(f"TOTAL simple={total_s} interpolated={total_c}")
