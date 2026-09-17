import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/onboarding/force_update_screen.dart';
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/reporting/ui/report_config_page.dart';
import 'package:money_companion/features/reporting/ui/report_preview_screen.dart';
import 'package:money_companion/features/subscriptions/bill_details_sheet.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// VISUAL CLOSURE — the shipping surfaces the earlier visual pass named but did
/// not open.
///
/// `V1_UI_ACCEPTANCE_MATRIX_VISUAL_2026-09-17.md` §6 listed twelve uninspected
/// surfaces and four unexercised overlays. Eight of them need nothing more than
/// a signed-in app driven into the right state, and they are captured here. The
/// four first-run onboarding screens need a signed-OUT session and live in
/// `onboarding_visual_capture_test.dart`; the three boot roots need an injected
/// bootstrap and live in `boot_states_capture_test.dart`.
///
/// Every surface below is driven into its real state through the app's own
/// code — the announcement DAO, the restore notifier, the app-lock flag, the
/// shipping repositories — never by pumping a widget in isolation. The point of
/// the exercise is a rendered screen someone looked at, and a screen reached by
/// a route the app does not actually take is not that screen.
///
/// Each surface is independent: a failure is recorded and the walk continues,
/// so one unreachable state cannot cost the other eleven their captures.
///
/// `demo_seed` runs first and seeds the ledger these surfaces need.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // DISARM THE APP LOCK BEFORE ANY TEST RUNS.
  //
  // `AppLockGate` locks on the first frame when this flag is set, and asks iOS
  // to authenticate. On a Simulator that prompt is the device-passcode sheet,
  // which is a NATIVE view sitting above Flutter and cannot be satisfied — the
  // shell never mounts and every test in the file dies on "shell never
  // mounted", including ones that have nothing to do with the lock.
  //
  // The flag is sticky: `visual_closure_capture_test` turns it on to capture
  // the locked screen, and a run killed between the capture and its restore
  // leaves the device unlaunchable. Two runs were lost to exactly that before
  // the cause was found, so clearing it is a precondition of every capture
  // file rather than a courtesy of the one that sets it.
  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
  });

  // Runs FIRST, and not only for the ledger. Dropping it to save four minutes
  // cost a whole run: with this file's `app.main()` the first in the process,
  // the shell never mounted and the walk died on "shell never mounted". Every
  // capture file in this repo calls `app.main()` as the SECOND caller, behind
  // demo_seed — that is the configuration they are known to work in.
  demo_seed.main();

  var surfaceConverted = false;
  Future<void> captureReady() async {
    if (surfaceConverted || !Platform.isAndroid) return;
    await binding.convertFlutterSurfaceToImage();
    surfaceConverted = true;
  }

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 12)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  /// Bounded wait for a finder — `pumpAndSettle` cannot be used anywhere in
  /// this app because several surfaces carry an indeterminate spinner or a
  /// shimmer that never reaches quiescence.
  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('visual closure captures', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;

    // PHASE LOGGING, not decoration. The first run of this file stalled with an
    // idle CPU, an unchanging log and no screenshots, and there was no way to
    // tell which await was hanging. Every step announces itself.
    void phase(String s) => debugPrint('[VC-PHASE] $s');

    phase('app.main');
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    if (_qaEmail.isEmpty) fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    phase('owner check');
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final client = supabase.Supabase.instance.client;
    // BOUNDED. The app restores its own session on launch, so a slow or
    // unreachable auth endpoint must not take the whole capture run with it —
    // the first attempt hung here for four minutes with nothing to show for it.
    // If the explicit sign-in cannot complete, the restored session is checked
    // instead and the run continues or aborts on its own terms.
    phase('sign in');
    String? userId;
    try {
      final res = await client.auth
          .signInWithPassword(email: _qaEmail, password: _qaPassword)
          .timeout(const Duration(seconds: 60));
      userId = res.user?.id;
    } catch (e) {
      debugPrint('[VC-PHASE] sign in failed/timed out: $e');
      userId = client.auth.currentUser?.id;
    }
    if (userId == null) {
      fail('no session: the explicit sign-in did not complete and none was '
          'restored, so the walk would measure a signed-out app');
    }
    if (userId != _qaUserId) {
      fail('ABORT — signed in as $userId, not the QA account');
    }
    phase('set identity');
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: userId);
    phase('reconcile');
    try {
      await AppSession.instance
          .reconcileAccountOnboarding(client)
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      debugPrint('[VC-PHASE] reconcile failed/timed out: $e');
    }
    phase('welcome flag');
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 45));
    if (!AppSession.instance.hasCompletedOnboarding) {
      phase('finish onboarding');
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 30));
    }
    phase('await shell');
    expect(await waitFor(tester, find.byType(AppShell),
            timeout: const Duration(seconds: 90)),
        isTrue,
        reason: 'shell never mounted');

    final shellElement = tester.element(find.byType(AppShell));
    final container = ProviderScope.containerOf(shellElement);
    final settingsRepo = container.read(userSettingsRepositoryProvider);
    final router = GoRouter.of(shellElement);
    final db = container.read(appDatabaseProvider);

    final failures = <String>[];
    final captured = <String>[];
    final notes = <String>[];

    Future<void> home() async {
      router.go('/');
      await settle(tester, budget: const Duration(seconds: 15));
    }

    /// Screenshot + record. Named `<lang>-<surface>` so the two languages sit
    /// next to each other in the evidence directory.
    Future<void> shoot(String lang, String name) async {
      await captureReady();
      await settle(tester, budget: const Duration(seconds: 3));
      await binding.takeScreenshot('vc-$lang-$name');
      captured.add('$lang/$name');
      debugPrint('[VC-PHASE] captured $lang/$name');
    }

    /// Runs one surface, recording rather than throwing. `restore` always runs,
    /// so a surface that changes global state cannot poison the next one.
    Future<void> surface(
      String lang,
      String name,
      Future<void> Function() body, {
      Future<void> Function()? restore,
    }) async {
      debugPrint('[VC-PHASE] surface start $lang/$name');
      try {
        await body();
        debugPrint('[VC-PHASE] surface ok $lang/$name');
      } catch (e, s) {
        debugPrint('[VC-PHASE] surface FAIL $lang/$name: $e');
        failures.add('[$lang] $name: $e\n$s');
      } finally {
        if (restore != null) {
          try {
            await restore();
          } catch (e) {
            failures.add('[$lang] $name: RESTORE FAILED — $e');
          }
        }
      }
    }

    /// Closes whatever modal is on top, bounded.
    Future<void> popAll() async {
      for (var i = 0; i < 6; i++) {
        final scaffold = find.byType(Scaffold);
        if (scaffold.evaluate().isEmpty) break;
        final nav = Navigator.of(tester.element(scaffold.first));
        if (!nav.canPop()) break;
        nav.pop();
        await settle(tester, budget: const Duration(seconds: 4));
      }
      await home();
    }

    Future<void> walk(String lang) async {
      final current = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(current.copyWith(language: lang));
      await home();

      // The language must have reached the widget tree before anything is
      // measured or captured. Three earlier walks screenshotted the first
      // surface after a switch while the tree still carried the old locale,
      // and read the stale copy as untranslated.
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      var carried = false;
      while (DateTime.now().isBefore(deadline)) {
        final shell = find.byType(Scaffold);
        if (shell.evaluate().isNotEmpty &&
            Localizations.localeOf(tester.element(shell.first)).languageCode ==
                lang) {
          carried = true;
          break;
        }
        await settle(tester, budget: const Duration(seconds: 2));
      }
      if (!carried) {
        failures.add('[$lang] the tree never carried the language — every '
            'capture below would be of the previous locale');
        return;
      }

      // ── 1. PlansScreen — the settings row that pushes it ─────────────────
      // §6 recorded this as having "no opener that takes only a context".
      // `PlansScreen.open(context)` takes exactly that, and settings calls it.
      await surface(lang, 'plans', () async {
        router.go('/settings');
        await settle(tester, budget: const Duration(seconds: 20));
        final l = tester.element(find.byType(Scaffold).first).l10n;
        final row = find.text(l.setPlans);
        if (row.evaluate().isEmpty) throw StateError('setPlans row not found');
        await tester.ensureVisible(row.first);
        await settle(tester, budget: const Duration(seconds: 3));
        await tester.tap(row.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 12));
        if (find.byType(PlansScreen).evaluate().isEmpty) {
          throw StateError('PlansScreen did not push');
        }
        await shoot(lang, 'plans');
      }, restore: popAll);

      // ── 2. MerchantOffersScreen — a real route, deep-linkable ────────────
      // `enable_coupons` ships OFF, so what a V1 user would see through a
      // campaign link is the calm empty state. That IS the shipping
      // appearance; capturing a populated one would show a screen V1 never
      // renders.
      await surface(lang, 'merchant-offers', () async {
        final merchants = await container.read(catalogMerchantsProvider.future);
        final id = merchants.keys.isEmpty ? 'unknown-merchant' : merchants.keys.first;
        notes.add('[$lang] merchant-offers: merchantId=$id '
            '(catalog holds ${merchants.length})');
        router.go('/coupons/merchant/$id');
        await settle(tester, budget: const Duration(seconds: 20));
        await shoot(lang, 'merchant-offers');
      }, restore: home);

      // ── 3. ReportPreviewScreen ───────────────────────────────────────────
      // §6 recorded the generation path as ad-gated. The ad coordinator is
      // fail-open and presents nothing without a loaded ad, so the gate is not
      // what stood in the way. The request built here is the config page's own
      // default state, field for field.
      await surface(lang, 'report-preview', () async {
        // Deliberately NOT on `/reports`: that path builds `ReportsScreen`
        // standalone, outside the shell, so `find.byType(AppShell)` comes back
        // empty there and the element lookup below throws "Bad state: No
        // element" — which is how the first run of this surface died. The
        // generation call needs a live context and ref, not a particular
        // screen, and the shell's own element is both.
        await home();
        final settings = await settingsRepo.getSettings();
        final request = ReportRequest(
          period: const MonthlyPeriod(),
          scope: const AllAccountsScope(),
          languageCode: lang,
          content: const ReportContentOptions(),
          privacyMode: settings.privacyModeEnabled,
        );
        final element = tester.element(find.byType(AppShell));
        final ref = element as WidgetRef;
        unawaited(runReportGeneration(element, ref, request));
        // Generation renders a PDF: it is slow, and the progress dialog it
        // shows first is itself a shipping surface worth a frame.
        await settle(tester, budget: const Duration(seconds: 6));
        await shoot(lang, 'report-progress');
        final arrived = await waitFor(tester, find.byType(ReportPreviewScreen),
            timeout: const Duration(seconds: 120));
        if (!arrived) throw StateError('ReportPreviewScreen never pushed');
        await settle(tester, budget: const Duration(seconds: 10));
        await shoot(lang, 'report-preview');
      }, restore: popAll);

      // ── 4. SHELL-RESTORING — the root AppBootLoader overlay ──────────────
      // Driven by the same notifier the sign-in restore flips.
      await surface(lang, 'shell-restoring', () async {
        appDataRestoring.value = true;
        await settle(tester, budget: const Duration(seconds: 4));
        final loader = find.byType(AppBootLoader);
        if (loader.evaluate().isEmpty) {
          throw StateError('AppBootLoader did not cover the app');
        }
        // The English capture of this overlay came back reading
        // «جارٍ تجهيز التطبيق...». The ARB, the generated English class and the
        // widget were all correct, so the locale underneath them was not —
        // record what the loader's OWN element resolves, and what state the
        // settings provider is in, rather than inferring it afterwards.
        final loaderLocale =
            Localizations.localeOf(tester.element(loader.first)).languageCode;
        final settingsState = container.read(userSettingsProvider);
        notes.add('[$lang] boot loader resolved locale=$loaderLocale, '
            'userSettings isLoading=${settingsState.isLoading} '
            'hasError=${settingsState.hasError} '
            'hasValue=${settingsState.hasValue} '
            'valueLang=${settingsState.valueOrNull?.language}');
        await shoot(lang, 'shell-restoring');
      }, restore: () async {
        appDataRestoring.value = false;
        await settle(tester, budget: const Duration(seconds: 4));
      });

      // ── 5. SHELL-APPLOCK-DEFAULT — NOT captured here, deliberately ───────
      // The locked state exists only while iOS is presenting its authentication
      // prompt, and that prompt is a native view: while it is up the engine
      // stops delivering vsync, so `tester.pump()` never returns and the live
      // test binding freezes. Two runs were lost here before that was
      // understood — and because `integration_test` only flushes screenshots to
      // the driver when the test body COMPLETES, a freeze here also discarded
      // every capture the walk had already taken.
      //
      // It is captured instead from the host, with `simctl io screenshot`,
      // which sees the whole device including the OS sheet — which is what the
      // user actually looks at. See `tool/applock_visual_proof.sh`.

      // ── 6. ForceUpdateScreen ─────────────────────────────────────────────
      // A force-update announcement is a LOCAL row; the screen reads it
      // through the shipping provider. Nothing here touches the server.
      await surface(lang, 'force-update', () async {
        final dao = RemoteAnnouncementsDao(db);
        final now = DateTime.now().toUtc();
        await dao.replaceAll([
          RemoteAnnouncement(
            id: 'qa-force-update',
            titleAr: 'حدّث قِرش للمتابعة',
            titleEn: 'Update Qirsh to continue',
            bodyAr: 'هذه النسخة لم تعد مدعومة. حدّث التطبيق للمتابعة.',
            bodyEn: 'This version is no longer supported. Update to continue.',
            severity: 'force_update',
            minAppVersion: null,
            maxAppVersion: null,
            actionLabelAr: 'تحديث',
            actionLabelEn: 'Update',
            actionUrl: 'https://apps.apple.com/app/id0000000000',
            validFrom: now.subtract(const Duration(days: 1)),
            validUntil: now.add(const Duration(days: 1)),
            isDismissible: false,
            priority: 100,
            isDismissed: false,
            dismissedAt: null,
            syncedAt: now,
          ),
        ]);
        container.invalidate(activeAnnouncementsProvider);
        container.invalidate(hasForceUpdateProvider);
        await home();
        final arrived = await waitFor(tester, find.byType(ForceUpdateScreen),
            timeout: const Duration(seconds: 30));
        if (!arrived) throw StateError('ForceUpdateScreen never took over');
        await shoot(lang, 'force-update');
      }, restore: () async {
        await RemoteAnnouncementsDao(db).replaceAll(const []);
        container.invalidate(activeAnnouncementsProvider);
        container.invalidate(hasForceUpdateProvider);
        await settle(tester, budget: const Duration(seconds: 10));
        await home();
      });

      // ── 6b. The announcement family, seeded so it renders at all ────────
      // `ForceUpdateScreen` reads `titleAr`/`bodyAr`/`actionLabelAr` with no
      // locale check. The banner on the dashboard and the announcements screen
      // read the same fields. None of it was ever visible to the bilingual
      // walk, because the QA catalog seeds zero announcements — an empty
      // surface has no copy to measure, so "0 untranslated strings" said
      // nothing about any of them.
      Future<void> seedInfoAnnouncement() async {
        final now = DateTime.now().toUtc();
        await RemoteAnnouncementsDao(db).replaceAll([
          RemoteAnnouncement(
            id: 'qa-info-announcement',
            titleAr: 'صيانة مجدولة',
            titleEn: 'Scheduled maintenance',
            bodyAr: 'سيتوقف التزامن لساعة مساء الجمعة.',
            bodyEn: 'Sync pauses for an hour on Friday evening.',
            severity: 'info',
            minAppVersion: null,
            maxAppVersion: null,
            actionLabelAr: 'التفاصيل',
            actionLabelEn: 'Details',
            actionUrl: null,
            validFrom: now.subtract(const Duration(days: 1)),
            validUntil: now.add(const Duration(days: 1)),
            isDismissible: true,
            priority: 10,
            isDismissed: false,
            dismissedAt: null,
            syncedAt: now,
          ),
        ]);
        container.invalidate(activeAnnouncementsProvider);
        container.invalidate(hasForceUpdateProvider);
      }

      Future<void> clearAnnouncements() async {
        await RemoteAnnouncementsDao(db).replaceAll(const []);
        container.invalidate(activeAnnouncementsProvider);
        container.invalidate(hasForceUpdateProvider);
        await settle(tester, budget: const Duration(seconds: 6));
        await home();
      }

      await surface(lang, 'announcement-banner', () async {
        await seedInfoAnnouncement();
        await home();
        await settle(tester, budget: const Duration(seconds: 12));
        await shoot(lang, 'announcement-banner');
      }, restore: clearAnnouncements);

      await surface(lang, 'announcements-screen', () async {
        await seedInfoAnnouncement();
        router.go('/announcements');
        await settle(tester, budget: const Duration(seconds: 16));
        await shoot(lang, 'announcements-screen');
      }, restore: clearAnnouncements);

      // ── 7. OVL-ACCOUNT-FORM — through the button, not a synthesised ref ──
      // §6 recorded this as needing a `WidgetRef` the walk could not
      // synthesise. It does not need one: `/accounts` carries the button that
      // supplies the real one.
      await surface(lang, 'account-form', () async {
        router.go('/accounts');
        await settle(tester, budget: const Duration(seconds: 20));
        final l = tester.element(find.byType(Scaffold).first).l10n;
        final add = find.text(l.accAddAccount);
        if (add.evaluate().isEmpty) throw StateError('add-account button absent');
        await tester.ensureVisible(add.first);
        await settle(tester, budget: const Duration(seconds: 3));
        await tester.tap(add.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 10));
        if (find.byType(BottomSheet).evaluate().isEmpty) {
          throw StateError('the account form did not open');
        }
        await shoot(lang, 'account-form');
      }, restore: popAll);

      // ── 8. OVL-CARD-FORM — same, from /cards ─────────────────────────────
      await surface(lang, 'card-form', () async {
        router.go('/cards');
        await settle(tester, budget: const Duration(seconds: 20));
        final l = tester.element(find.byType(Scaffold).first).l10n;
        final add = find.byTooltip(l.cardAddCard);
        if (add.evaluate().isEmpty) throw StateError('add-card button absent');
        await tester.tap(add.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 10));
        if (find.byType(BottomSheet).evaluate().isEmpty) {
          throw StateError('the card form did not open');
        }
        await shoot(lang, 'card-form');
      }, restore: popAll);

      // ── 9. OVL-BILL-DETAIL — needs a bill to exist ───────────────────────
      // The QA ledger seeds DETECTED subscriptions that were never enabled, so
      // `getAll()` is empty and the sheet has nothing to render. One bill is
      // written through the shipping repository — the same path the bill form
      // commits through — inspected, then deleted.
      await surface(lang, 'bill-details', () async {
        final repo = container.read(billRepositoryProvider);
        var bills = await repo.getAll();
        if (bills.isEmpty) {
          await repo.save(BillEntity(
            // Per language: the Arabic pass's row is deleted in its restore,
            // but re-inserting the SAME primary key still hit
            // "UNIQUE constraint failed: subscriptions.id" on the English
            // pass, so the two passes no longer share an id.
            id: 'qa-visual-bill-$lang',
            name: lang == 'en' ? 'Streaming plan' : 'اشتراك البث',
            amountMoney: Money(4500, 'SAR'),
            currency: 'SAR',
            type: BillType.subscription,
            frequency: BillFrequency.monthly,
            nextDueDate: DateTime.now().add(const Duration(days: 9)),
            reminderOn: true,
            isConfirmed: true,
            createdAt: DateTime.now(),
          ));
          bills = await repo.getAll();
        }
        if (bills.isEmpty) throw StateError('the bill did not persist');
        router.go('/subscriptions');
        await settle(tester, budget: const Duration(seconds: 20));
        final host = tester.element(find.byType(Scaffold).first);
        unawaited(BillDetailsSheet.show(host, bills.first));
        await settle(tester, budget: const Duration(seconds: 10));
        if (find.byType(BillDetailsSheet).evaluate().isEmpty) {
          throw StateError('the bill details sheet did not open');
        }
        await shoot(lang, 'bill-details');
      }, restore: () async {
        await popAll();
        try {
          await container
              .read(billRepositoryProvider)
              .delete('qa-visual-bill-$lang');
        } catch (_) {
          // Already gone, or never written — nothing to undo.
        }
      });
    }

    await walk('ar');
    await walk('en');

    final last = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(last.copyWith(language: 'ar'));
    await settle(tester);

    debugPrint('[VC] captured ${captured.length}: ${captured.join(", ")}');
    for (final n in notes) {
      debugPrint('[VC-NOTE] $n');
    }
    for (final f in failures) {
      debugPrint('[VC-FAIL] $f');
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
    // 10 surfaces + the report progress dialog, in two languages. The app lock
    // is captured from the host instead; see the note above surface 5.
    expect(captured.length, 22,
        reason: 'expected 11 captures × 2 languages, got ${captured.length}: '
            '${captured.join(", ")}');
  }, timeout: const Timeout(Duration(minutes: 45)));
}
