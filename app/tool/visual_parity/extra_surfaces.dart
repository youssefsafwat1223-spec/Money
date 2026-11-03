// Simulator-only entry points for the production UI. This file is imported by
// tool/visual_parity/main.dart, never by lib/main.dart. It does not copy private
// widgets or grant session/consent authority. Every data-backed form reads the
// current in-memory fixture; all modal return values are deliberately ignored.
import 'dart:async';
import 'report_generation_surfaces.dart';
import 'privacy_pending_surfaces.dart';
import 'privacy_refresh_surfaces.dart';
import 'restore_negative_surfaces.dart';
import 'restore_confirmation_cancel_surface.dart';
import 'brand_continue_failure_surfaces.dart';
import 'app_lock_failure_surfaces.dart';
import 'auth_platform_surfaces.dart';
import 'activity_duplicate_surfaces.dart';
import 'capability_read_surfaces.dart';
import 'extended_surfaces.dart';
import 'local_read_surfaces.dart';
import 'planning_repair_surfaces.dart';
import 'form_outcome_surfaces.dart';
import 'paste_outcome_surfaces.dart';
import 'financial_state_surfaces.dart';
import 'deletion_status_surfaces.dart';
import 'data_transfer_surfaces.dart';
import 'registration_state_surfaces.dart';
import 'settings_preference_surfaces.dart';
import 'bank_discovery_outcome_surfaces.dart';
import 'confirmation_outcome_surfaces.dart';
import 'account_guard_surfaces.dart';
import 'budget_outcome_surfaces.dart';
import 'manual_paste_result_surfaces.dart';
import 'pending_age_surfaces.dart';
import 'local_read_notice_surfaces.dart';
import 'goal_contribution_outcome_surfaces.dart';
import 'manual_edit_outcome_surfaces.dart';
import 'card_outcome_surfaces.dart';
import 'brand_asset_atlas.dart';
import 'brand_mark_visibility_surfaces.dart';
import 'confirmation_awaiting_surfaces.dart';
import 'plan_delete_outcome_surfaces.dart';
import 'bill_payment_outcome_surfaces.dart';
import 'bill_partial_link_surfaces.dart';
import 'paste_batch_confirm_surfaces.dart';
import 'coupon_artwork_fallback_surfaces.dart';
import 'conflict_failure_surfaces.dart';
import 'auth_failure_surfaces.dart';
import 'country_save_failure_surfaces.dart';
import 'transaction_details_failure_surfaces.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/unsynced_inventory.dart';
import 'package:money_companion/core/theme/widgets/glass_pickers.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/usecases/account_deletion.dart';
import 'package:money_companion/features/accounts/account_deletion_sheet.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';
import 'package:money_companion/features/budgets/allocate_income_sheet.dart';
import 'package:money_companion/features/cards/card_form_sheet.dart';
import 'package:money_companion/features/cards/my_cards_screen.dart';
import 'package:money_companion/features/capture/sms_permission_screen.dart';
import 'package:money_companion/features/capture/widgets/sms_capture_disclosure.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/onboarding/ios_shortcut_guide.dart';
import 'package:money_companion/features/planning_sync/planning_conflicts_sheet.dart';
import 'package:money_companion/features/plans/plan_form_sheet.dart';
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/report_ads/report_ad_notice.dart';
import 'package:money_companion/features/reporting/ui/report_config_page.dart';
import 'package:money_companion/features/settings/sign_out_sheet.dart';
import 'package:money_companion/features/settings/sync_status_ui.dart';
import 'package:money_companion/features/subscriptions/bill_details_sheet.dart';
import 'package:money_companion/features/subscriptions/bill_form_sheet.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/features/transactions/widgets/change_category_sheet.dart';
import 'package:money_companion/features/transactions/widgets/confirm_transaction_sheet.dart';

/// Public production surfaces that can be opened without cloning private UI.
/// Suffixes are fixture identifiers, not real account or transaction identifiers.
/// The loopback controller should expose these keys as part of its manifest.
const visualParityExtraSurfaceKeys = <String>[
  ...visualParityExtendedSurfaceKeys,
  ...visualParityLocalReadSurfaceKeys,
  ...visualParityPlanningRepairKeys,
  ...visualParityFormOutcomeKeys,
  ...visualParityPasteOutcomeKeys,
  ...visualParityFinancialStateSurfaceKeys,
  ...visualParityDeletionStatusKeys,
  ...visualParityDataTransferSurfaceKeys,
  ...visualParityRegistrationStateKeys,
  ...visualParitySettingsPreferenceKeys,
  ...visualParityBankDiscoveryOutcomeKeys,
  ...visualParityConfirmationOutcomeKeys,
  ...visualParityAccountGuardKeys,
  ...visualParityBudgetOutcomeKeys,
  ...visualParityManualPasteResultKeys,
  ...visualParityPendingAgeKeys,
  ...visualParityLocalReadNoticeKeys,
  ...visualParityGoalContributionOutcomeKeys,
  ...visualParityManualEditOutcomeKeys,
  ...visualParityCardOutcomeKeys,
  ...visualParityBrandAssetAtlasKeys,
  ...visualParityBrandMarkVisibilityKeys,
  ...visualParityConfirmationAwaitingKeys,
  ...visualParityPlanDeleteOutcomeKeys,
  ...visualParityBillPaymentOutcomeKeys,
  ...visualParityBillPartialLinkKeys,
  ...visualParityPasteBatchConfirmKeys,
  ...visualParityCouponArtworkFallbackKeys,
  ...visualParityConflictFailureKeys,
  ...visualParityAuthFailureKeys,
  ...visualParityCountryFailureKeys,
  ...visualParityRestoreNegativeKeys,
  visualParityRestoreCancelKey,
  'brandContinueStorageFailure',
  'appLockStorageFailure',
  ...visualParityTransactionFailureKeys,
  'accountNew',
  'accountEdit:<fixtureAccountId>',
  'accountDeleteChoices',
  'accountDeleteChoicesEmpty',
  'cardNew',
  'cardEdit:<fixtureCardId>',
  'cards',
  'subscriptionNew',
  'installmentNew',
  'billServicePicker',
  'billEdit:<fixtureBillId>',
  'billDetail:<fixtureBillId>',
  'planNew',
  'planEdit:<fixturePlanId>',
  'plans',
  'allocateIncome',
  'manualEdit:<fixtureTransactionId>',
  'confirmTransaction:<fixtureTransactionId>',
  'changeCategory:<fixtureTransactionId>',
  'reportConfig',
  'privacyScheduledReview',
  'privacyRefreshReview',
  'authUnsupportedReview',
  'activityDuplicateReview',
  'activityDuplicateClearOwnFlag',
  'captureCapabilityOn',
  'captureCapabilityGrantedOff',
  'captureCapabilityDenied',
  'captureCapabilityUnavailable',
  'reportGenerationFailure',
  'reportGenerationCancel',
  'reportAdNotice',
  'datePicker',
  'timePicker',
  'dateRangePicker',
  'signout',
  'signoutPending',
  'removeDataConfirmation',
  'smsPermission',
  'smsDisclosure',
  'shortcutGuide',
  'syncStatus',
  'planningConflicts',
];

/// These production controls are private or depend on authority/platform state.
/// Use actual screen taps for private controls; do not create approximations.
const visualParityUnsupportedSurfaces = <String, String>{
  'replaceConfirmation': 'Testing-only production seam; use actual import replacement flow.',
  'accountSelector': 'Private Activity/Dashboard picker; open using its real header control.',
  'rangeSelector': 'Private screen-specific range picker; use real header control.',
  'categoryFilter': 'Private Activity filter; use real category control.',
  'smartInbox': 'Private Activity sheet; seed captured-message fixture and tap banner.',
  'duplicates': 'Private Activity sheet; seed suspected duplicate and tap review banner.',
  'budgetDetail': 'Private budget-period sheet; tap the real populated budget card.',
  'goalContribute': 'Private contribution sheet; open real goal detail and tap Add.',
  'planDetail': 'Private plan detail; open Plans and tap actual plan card.',
  'planLinkTransaction': 'Private nested control; open real plan detail and tap Link.',
  'cardAttachExisting': 'Private Cards control; open actual card overflow action.',
  'transactionCardLink': 'Private transaction detail control; tap its Card row.',
  'transactionCurrencyPrice': 'Private transaction pricing dialog; use a foreign-currency pending fixture.',
  'billRecordPayment': 'Private BillDetails control; open billDetail and tap Record payment.',
  'billDeletePayment': 'Private BillDetails control; seed payment then use real delete action.',
  'pasteBatchResults': 'Private paste result sheet; requires actual local fixture ingestion.',
  'profileEdit': 'Private Settings control; open Settings and tap profile field.',
  'settingsPicker': 'Private Settings control; tap actual country/currency/language field.',
  'categories': 'Private Settings manager; open actual Categories control.',
  'categoryEdit': 'Private Settings form; open actual category manager then Edit.',
  'quietHours': 'Private Settings control; use actual Notifications tab.',
  'about': 'Private Settings info sheet; tap About in the real screen.',
  'support': 'Private Settings info sheet; tap Contact support in the real screen.',
  'consent': 'Read-only management disclosure available as consentManagement; grant/revoke success still requires genuine committed capability.',
  'authSuccess': 'Requires native provider/auth session; this offline harness does not fabricate authentication.',
  'localReadAuthority': 'Presentation is available as localReadPresentation; genuine admission still requires verified local-read authority and isolated security tests.',
  'restoreSuccess': 'Requires backup/key/runtime state; no credential or production backup access.',
  'deleteAccountResult': 'Requires deletion protocol/authority; use isolated existing deletion tests.',
  'nativeNotificationPermission': 'OS permission state, not an application modal; inspect separately on disposable Simulator.',
};

const _pendingFixture = UnsyncedInventory(
  ledgerOutbox: 3,
  planningOutbox: 2,
  smartInboxPending: 1,
  localOnlyCards: 1,
  senderMappingsPending: 0,
  notificationLogPending: 0,
  unprovenFinancialRows: 1,
  unresolvedConflicts: 1,
);

/// Schedules an actual production modal and returns as soon as it is pushed.
/// Awaiting the modal itself would block the HTTP automation until dismissal.
/// Future failures still reach FlutterError and the harness's error recorder.
void _open(Future<Object?> future) {
  unawaited(future.then<void>((_) {}, onError: (Object error, StackTrace stack) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'Qirsh visual parity fixture',
    ));
  }));
}

/// Returns false for unknown/private keys or a missing synthetic fixture row.
/// Throws if this tool is accidentally run with a backend or disk database.
/// The guard never prints database paths or reads credentials.
Future<bool> openVisualParitySurface(
  BuildContext context,
  WidgetRef ref,
  String key,
) async {
  if (kReleaseMode || SupabaseConfig.isConfigured) {
    throw StateError('visual_parity_requires_debug_without_backend');
  }
  final db = ref.read(appDatabaseProvider);
  final attached = await db.customSelect('PRAGMA database_list').get();
  final memory = attached.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty);
  if (!memory) throw StateError('visual_parity_requires_in_memory_database');
  if (!context.mounted) return false;
  if (await openVisualParityPlanningRepair(context, ref, key)) return true;
  if (!context.mounted) return false;

  final split = key.indexOf(':');
  final surface = split < 0 ? key : key.substring(0, split);
  final id = split < 0 ? null : key.substring(split + 1);
  switch (surface) {
    case 'accountNew':
      _open(showAccountForm(context, ref));
    case 'accountEdit':
      final account = id == null ? null : await ref.read(accountRepositoryProvider).getById(id);
      if (account == null || !context.mounted) return false;
      _open(showAccountForm(context, ref, account: account));
    case 'accountDeleteChoices':
    case 'accountDeleteChoicesEmpty':
      final accounts = await ref.read(accountRepositoryProvider).getAll();
      if (!context.mounted) return false;
      final populated = surface == 'accountDeleteChoices';
      // Pure read-only impact snapshot. Confirm returns a decision value only;
      // this dispatcher never invokes an account-deletion service.
      _open(AccountDeletionSheet.show(context, AccountDeletionImpact(
        accountId: 'visual-fixture-account',
        accountCurrency: 'EGP',
        transactionsToDetach: populated ? 3 : 0,
        cardsToArchive: populated ? 1 : 0,
        budgetsToArchive: populated ? 1 : 0,
        goals: populated ? const [AccountDependent(
          id: 'visual-fixture-goal', name: 'Preview goal', currency: 'EGP', amount: 1500,
        )] : const [],
        subscriptions: populated ? const [AccountDependent(
          id: 'visual-fixture-subscription', name: 'Netflix', currency: 'EGP', amount: 250,
        )] : const [],
        successorCandidates: accounts,
      )));
    case 'cardNew':
      _open(showCardForm(context, ref));
    case 'cardEdit':
      final card = id == null ? null : await ref.read(cardRepositoryProvider).getById(id);
      if (card == null || !context.mounted) return false;
      _open(showCardForm(context, ref, card: card));
    case 'cards':
      _open(MyCardsScreen.open(context));
    case 'subscriptionNew':
      _open(BillFormSheet.show(context, initialType: BillType.subscription));
    case 'installmentNew':
      _open(BillFormSheet.show(context, initialType: BillType.installment));
    case 'billServicePicker':
      _open(BillFormSheet.show(context));
    case 'billEdit':
    case 'billDetail':
      final bill = id == null ? null : await ref.read(billRepositoryProvider).getById(id);
      if (bill == null || !context.mounted) return false;
      _open(surface == 'billEdit'
          ? BillFormSheet.show(context, bill: bill)
          : BillDetailsSheet.show(context, bill));
    case 'planNew':
      _open(PlanFormSheet.show(context));
    case 'planEdit':
      final plan = id == null ? null : await ref.read(planRepositoryProvider).getById(id);
      if (plan == null || !context.mounted) return false;
      _open(PlanFormSheet.show(context, existing: plan));
    case 'plans':
      _open(PlansScreen.open(context));
    case 'allocateIncome':
      _open(AllocateIncomeSheet.show(context));
    case 'manualEdit':
    case 'changeCategory':
      final tx = id == null ? null : await ref.read(transactionRepositoryProvider).getById(id);
      if (tx == null || !context.mounted) return false;
      if (surface == 'manualEdit') {
        _open(ManualTransactionSheet.show(context, transaction: tx));
      } else {
        final catalog = await ref.read(categoryCatalogProvider.future);
        if (!context.mounted) return false;
        _open(showChangeCategorySheet(context, tx, catalog));
      }
    case 'confirmTransaction':
      final tx = id == null ? null : await ref.read(transactionRepositoryProvider).getById(id);
      if (tx == null || !context.mounted) return false;
      _open(showConfirmTransactionSheet(context, tx.id));
    case 'appLockStorageFailure':
      return openVisualParityAppLockFailure(context, ref);
    case 'brandContinueStorageFailure':
      return openVisualParityBrandContinueFailure(context, ref);
    case visualParityRestoreCancelKey:
      return openVisualParityRestoreCancel(context, ref, surface);
    case 'restoreWrongPassphrase':
    case 'restorePreparationFailure':
      return openVisualParityRestoreNegative(context, ref, surface);
    case 'reportGenerationFailure':
    case 'reportGenerationCancel':
      _open(Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => ReportGenerationReview(
          waitForCancel: surface == 'reportGenerationCancel',
        ),
      )));
    case 'captureCapabilityOn':
    case 'captureCapabilityGrantedOff':
    case 'captureCapabilityDenied':
    case 'captureCapabilityUnavailable':
      _open(Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => CaptureCapabilityReview(
          mode: surface.substring('captureCapability'.length),
        ),
      )));
    case 'activityDuplicateReview':
    case 'activityDuplicateClearOwnFlag':
      return openActivityDuplicateReview(context, ref,
          clear: surface == 'activityDuplicateClearOwnFlag');
    case 'authUnsupportedReview':
      _open(Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => const AuthUnsupportedReview(),
      )));
    case 'privacyRefreshReview':
      _open(Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => const PrivacyRefreshReview(),
      )));
    case 'privacyScheduledReview':
      _open(Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => const PrivacyPendingReview(),
      )));
    case 'reportConfig':
      _open(showReportConfigPage(context));
    case 'reportAdNotice':
      _open(showReportAdNotice(context));
    case 'datePicker':
      _open(showGlassDatePicker(context: context,
        initialDate: DateTime(2026, 10, 29),
        firstDate: DateTime(2020), lastDate: DateTime(2040)));
    case 'timePicker':
      _open(showGlassTimePicker(context: context,
        initialTime: const TimeOfDay(hour: 22, minute: 30)));
    case 'dateRangePicker':
      _open(showDateRangePicker(context: context,
        initialDateRange: DateTimeRange(start: DateTime(2026, 10), end: DateTime(2026, 10, 29)),
        firstDate: DateTime(2020), lastDate: DateTime(2040)));
    case 'signout':
      _open(showSignOutSheet(context));
    case 'signoutPending':
      _open(showSignOutSheet(context, pending: _pendingFixture));
    case 'removeDataConfirmation':
      _open(confirmRemoveData(context, pending: _pendingFixture));
    case 'smsPermission':
      _open(SmsPermissionScreen.showSheet(context));
    case 'smsDisclosure':
      _open(showSmsCaptureDisclosure(context));
    case 'shortcutGuide':
      _open(showIosShortcutSheet(context));
    case 'syncStatus':
      _open(showSyncStatusSheet(context));
    case 'planningConflicts':
      _open(PlanningConflictsSheet.show(context));
    default:
      if (await openVisualParityPasteBatchConfirm(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityBillPartialLink(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityCountryFailure(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityTransactionFailure(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityAuthFailure(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityConflictFailure(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityCouponArtworkFallback(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityBillPaymentOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityPlanDeleteOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityConfirmationAwaiting(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityBrandMarkVisibility(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityBrandAssetAtlas(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityCardOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityManualEditOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityGoalContributionOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityLocalReadNotice(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityPendingAge(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityManualPasteResult(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityBudgetOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityAccountGuard(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityConfirmationOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityBankDiscoveryOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParitySettingsPreference(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityRegistrationState(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityDataTransferSurface(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityDeletionStatus(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityFinancialStateSurface(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityPasteOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityFormOutcome(context, ref, key)) return true;
      if (!context.mounted) return false;
      if (await openVisualParityLocalReadSurface(context, ref, key)) return true;
      if (!context.mounted) return false;
      return openVisualParityExtendedSurface(context, ref, key);
  }
  return true;
}

/// Mount under the fixture's ProviderScope and Navigator. The optional callback
/// lets its loopback controller retain the actual mounted WidgetRef/context.
class VisualParitySurfaceBridge extends ConsumerWidget {
  const VisualParitySurfaceBridge({super.key, required this.onReady});

  final void Function(BuildContext context, WidgetRef ref) onReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) onReady(context, ref);
    });
    return const SizedBox.shrink();
  }
}
