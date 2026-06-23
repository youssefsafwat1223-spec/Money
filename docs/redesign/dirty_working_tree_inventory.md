# Dirty Working Tree Inventory

Based on the `git status` and `git diff` outputs, here is the classification of the currently modified and untracked files in the working tree.

## A. Redesign documentation
* **Files (4):**
  * `../docs/design/`
  * `../docs/design_audit/`
  * `../docs/redesign/`
  * `../prototype/new_mali_redesign.html`
* **Safe to commit now:** Yes
* **Keep for Phase 1/2:** Yes
* **Stash:** No
* **Discard:** No

## B. Test baseline fix
* **Files (1):**
  * `test/data/catalog_seed_loader_test.dart`
* **Safe to commit now:** Yes
* **Keep for Phase 1/2:** Yes
* **Stash:** No
* **Discard:** No

## C. Phase 1 token work already started
* **Files (9):**
  * `lib/core/theme/app_colors.dart`
  * `lib/core/theme/app_gradients.dart`
  * `lib/core/theme/app_shadows.dart`
  * `lib/core/theme/app_spacing.dart`
  * `lib/core/theme/app_theme.dart`
  * `lib/core/theme/app_typography.dart`
  * `lib/core/utils/app_lucide_icons.dart`
  * `lib/core/utils/lucide_icon_map.dart`
  * `lib/features/common/motion.dart`
* **Safe to commit now:** No (Wait for Phase 1 completion)
* **Keep for Phase 1/2:** Yes
* **Stash:** Optional (Can stay in working tree for Phase 1)
* **Discard:** No

## D. Phase 2 component work already started
* **Files (13):**
  * `lib/features/common/app_button.dart`
  * `lib/features/common/app_card.dart`
  * `lib/features/common/app_empty_state.dart`
  * `lib/features/common/app_insight_card.dart`
  * `lib/features/common/app_metric_card.dart`
  * `lib/features/common/app_pill_tab_bar.dart`
  * `lib/features/common/app_screen_scaffold.dart`
  * `lib/features/common/app_transaction_row.dart`
  * `lib/features/common/charts/spending_charts.dart`
  * `lib/features/common/section_hero_header.dart`
  * `lib/features/common/vault_widget.dart`
  * `lib/features/common/widgets.dart`
  * `lib/features/common/widgets/announcement_banner.dart`
* **Safe to commit now:** No
* **Keep for Phase 1/2:** Yes
* **Stash:** Yes (Stash until Phase 2 begins)
* **Discard:** No

## E. Screen redesign work already started
* **Files (38):**
  * `lib/app.dart`
  * `lib/core/router/app_router.dart`
  * `lib/features/accounts/accounts_screen.dart`
  * `lib/features/achievements/achievements_screen.dart`
  * `lib/features/app/app_shell.dart`
  * `lib/features/backup/backup_screen.dart`
  * `lib/features/budgets/budget_form_screen.dart`
  * `lib/features/budgets/budgets_screen.dart`
  * `lib/features/capture/capture_entry_sheet.dart`
  * `lib/features/capture/manual_paste_screen.dart`
  * `lib/features/capture/sms_permission_screen.dart`
  * `lib/features/dashboard/dashboard_screen.dart`
  * `lib/features/foundation/foundation_home_screen.dart`
  * `lib/features/goals/goal_details_screen.dart`
  * `lib/features/goals/goal_form_screen.dart`
  * `lib/features/goals/goals_screen.dart`
  * `lib/features/onboarding/auth_screen.dart`
  * `lib/features/onboarding/first_transaction_screen.dart`
  * `lib/features/onboarding/force_update_screen.dart`
  * `lib/features/onboarding/listening_screen.dart`
  * `lib/features/onboarding/method_screen.dart`
  * `lib/features/onboarding/onboarding_options.dart`
  * `lib/features/onboarding/onboarding_screen.dart`
  * `lib/features/onboarding/otp_screen.dart`
  * `lib/features/reports/reports_screen.dart`
  * `lib/features/settings/privacy_screen.dart`
  * `lib/features/settings/settings_screen.dart`
  * `lib/features/subscriptions/bill_form_sheet.dart`
  * `lib/features/subscriptions/subscriptions_screen.dart`
  * `lib/features/transactions/manual_transaction_sheet.dart`
  * `lib/features/transactions/transaction_details_screen.dart`
  * `lib/features/transactions/transactions_screen.dart`
  * `lib/features/transactions/widgets/change_category_sheet.dart`
  * `lib/features/transactions/widgets/confirm_transaction_sheet.dart`
  * `lib/l10n/app_ar.arb`
  * `lib/l10n/app_en.arb`
  * `lib/l10n/app_localizations.dart`
  * `lib/l10n/app_localizations_ar.dart`
  * `lib/l10n/app_localizations_en.dart`
* **Safe to commit now:** No
* **Keep for Phase 1/2:** No (Belongs to later phases)
* **Stash:** Yes (Stash heavily so they don't interfere with Phase 1/2 base)
* **Discard:** No

## F. Business logic / risky changes
* **Files (57):**
  * `assets/catalog/countries.json`
  * `assets/catalog/currencies.json`
  * `lib/core/auth/auth_service.dart`
  * `lib/core/auth/supabase_auth_service.dart`
  * `lib/core/backend/supabase_access_token.dart`
  * `lib/core/backup/backup_snapshot_builder.dart`
  * `lib/core/backup/restore_backup_usecase.dart`
  * `lib/core/di/app_providers.dart`
  * `lib/core/privacy/data_wipe_service.dart`
  * `lib/core/security/app_lock_gate.dart`
  * `lib/core/session/app_session.dart`
  * `lib/data/catalog/announcement_service.dart`
  * `lib/data/catalog/catalog_daos.dart`
  * `lib/data/catalog/catalog_sync_service.dart`
  * `lib/data/db/app_database.dart`
  * `lib/data/db/database_seed.dart`
  * `lib/data/repositories/drift_budget_repository.dart`
  * `lib/data/repositories/drift_gamification_repository.dart`
  * `lib/data/repositories/drift_goal_repository.dart`
  * `lib/data/repositories/drift_repository_support.dart`
  * `lib/data/repositories/drift_transaction_repository.dart`
  * `lib/data/repositories/drift_user_settings_repository.dart`
  * `lib/domain/entities/budget_entity.dart`
  * `lib/domain/entities/goal_entity.dart`
  * `lib/domain/entities/supporting_entities.dart`
  * `lib/domain/repositories/budget_repository.dart`
  * `lib/domain/repositories/transaction_repository.dart`
  * `lib/domain/usecases/add_transaction_usecase.dart`
  * `lib/domain/usecases/budget_progress_usecase.dart`
  * `lib/domain/usecases/user_settings_usecases.dart`
  * `lib/engine/ai/ai_parser_client.dart`
  * `lib/engine/ai/ai_sender_failure_tracker.dart`
  * `lib/engine/ai/grounding_check.dart`
  * `lib/engine/categorization/category.dart`
  * `lib/engine/categorization/category_seeds.dart`
  * `lib/engine/parser/bank_profile.dart`
  * `lib/engine/parser/normalizer.dart`
  * `lib/engine/parser/parser_engine.dart`
  * `lib/features/budgets/budgets_providers.dart`
  * `lib/features/capture/services/captured_message_processor.dart`
  * `lib/features/dashboard/dashboard_providers.dart`
  * `lib/features/reports/reports_providers.dart`
  * `lib/features/transactions/transactions_providers.dart`
  * `test/data/app_database_recovery_test.dart`
  * `test/data/catalog_sync_test.dart`
  * `test/data/gamification_repository_test.dart`
  * `test/data/repository_test.dart`
  * `test/data/sender_bank_mapping_repository_test.dart`
  * `test/domain/budget_progress_usecase_test.dart`
  * `test/domain/merchant_feedback_privacy_test.dart`
  * `test/engine/ai_cascade_test.dart`
  * `test/engine/ai_sender_failure_tracker_test.dart`
  * `test/engine/categorizer_test.dart`
  * `test/engine/fixtures/bank_sms_golden_fixtures.dart`
  * `test/engine/normalizer_test.dart`
  * `test/engine/parser_engine_test.dart`
  * `test/features/capture/ingest_captured_message_usecase_test.dart`
  * `test/features/onboarding/currency_keywords_test.dart`
  * `test/widget_test.dart`
  * `../supabase/functions/parse-sms/index.ts`
* **Safe to commit now:** No (Not part of UI redesign)
* **Keep for Phase 1/2:** No
* **Stash:** Yes (Or review carefully)
* **Discard:** Human review required. The redesign contract forbids touching these files.

## G. Generated / build / junk files
* **Files (~105):**
  * `../.DS_Store`, `../docs/.DS_Store`
  * `../admin/.next/...` (various cache/build files)
  * `../supabase/.temp/cli-latest`
  * `macos/Podfile.lock`
  * `patch_tx.py`
  * `patch_tx_fix.py`
* **Safe to commit now:** No
* **Keep for Phase 1/2:** No
* **Stash:** No
* **Discard:** Yes

## H. Unknown / needs human review
* **Files (6):**
  * `../admin/app/(admin)/announcements/page.tsx`
  * `../admin/app/api/`
  * `../supabase/supabase/`
  * `ios/Runner/Info.plist`
  * `macos/Runner.xcodeproj/project.pbxproj`
  * `macos/Runner.xcworkspace/contents.xcworkspacedata`
* **Safe to commit now:** No
* **Keep for Phase 1/2:** No
* **Stash:** Yes
* **Discard:** Human review required.

---

## Exact Recommendation for Next Action

1. **Commit Groups A & B**: Stage and commit the redesign documentation and the catalog seed test fix as the official `chore: Phase 0 baseline`.
2. **Review Group F & H**: Discuss the business logic changes (Group F) and unknown files (Group H) with the team. If they represent valid concurrent backend work, they should be isolated to a separate branch.
3. **Stash Groups D & E**: Stash the Phase 2 components and Screen redesigns so they don't crowd the working tree while Phase 1 is executed.
4. **Discard Group G**: Clean the untracked build caches and `.DS_Store` files.
5. **Keep Group C**: Leave the Phase 1 token files in the working tree to proceed with the Phase 1 implementation.
