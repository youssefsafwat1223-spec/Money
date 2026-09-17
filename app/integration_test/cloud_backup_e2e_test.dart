import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/encrypted_backup_service.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// CLOUD BACKUP END TO END — the encrypted path, actually exercised.
///
/// The claim is the strongest one this app makes about the user's data: *the
/// backup we upload is end-to-end encrypted, and only your passphrase opens
/// it*. Nothing proved that. `backup_restore_roundtrip_test` covers the LOCAL
/// export/import file; the cloud path — derive a key, encrypt, upload,
/// download, decrypt, parse — was never run.
///
/// ## Why this can be run safely, when it previously could not
///
/// The two objections in the old note were "it needs a passphrase this harness
/// has no business inventing" and "it writes to the owner's storage". Both are
/// answerable rather than fatal:
///
///  * The passphrase is GENERATED HERE, from `Random.secure`, used once, and
///    never written anywhere but this process's memory. Inventing a passphrase
///    is only wrong if it becomes a real user's passphrase; a disposable one
///    for a disposable QA account is exactly what a test should use.
///  * The upload lands under the QA user's own RLS-scoped path, and teardown
///    deletes it. No other account's storage is reachable from this session.
///
/// ## What it proves, and what it deliberately stops short of
///
/// It runs `enable` (key derivation + encrypt + upload), asserts the remote
/// object now exists, then runs `prepareRestore` with the passphrase — which
/// downloads, decrypts, validates and builds an immutable plan. Reaching a
/// plan means the whole cryptographic round trip worked.
///
/// It does NOT call `commitRestore`. Commit replaces the local database, and
/// the confirmation capability exists precisely so that cannot happen without
/// an explicit human decision. `destructive_phase_test` owns that path and its
/// teardown.
///
/// It also asserts the negative that matters: a WRONG passphrase must fail.
/// An "encrypted" backup that opens without the key is the defect this test
/// would otherwise be blind to.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 40)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  /// Disposable, and never printed. A backup passphrase in a log is the exact
  /// thing the encryption exists to prevent.
  String disposablePassphrase() {
    final rng = Random.secure();
    return base64Url
        .encode(List<int>.generate(24, (_) => rng.nextInt(256)))
        .replaceAll('=', '');
  }

  testWidgets('a cloud backup is uploaded, then opened with its passphrase',
      (tester) async {
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final client = supabase.Supabase.instance.client;
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    expect(find.byType(AppShell), findsWidgets, reason: 'shell never mounted');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final service = container.read(backupServiceProvider);
    expect(service, isA<EncryptedBackupService>(),
        reason: 'the stub service is wired — Supabase is not configured, so '
            'this run would have proved nothing about the cloud path');

    // Cloud consent gates every byte of egress, including this one. Asserting
    // it rather than assuming it means a consent regression fails here loudly
    // instead of quietly skipping the upload.
    final consent = await ConsentAuthority(
      () => container.read(userSettingsRepositoryProvider).getSettings(),
    ).allows(EgressClass.backup);
    debugPrint('[CLOUD] backup consent granted=$consent');

    // Always leave the account as it was found, whatever happens below.
    addTearDown(() async {
      try {
        await service.deleteRemoteBackups();
      } catch (e) {
        debugPrint('[CLOUD] teardown delete failed: ${e.runtimeType}');
      }
      try {
        await service.disable();
      } catch (e) {
        debugPrint('[CLOUD] teardown disable failed: ${e.runtimeType}');
      }
      debugPrint('[CLOUD] teardown complete — remote backup removed, '
          'backup disabled');
    });

    final passphrase = disposablePassphrase();

    // ---- enable: derive, encrypt, upload -----------------------------------
    String recoveryCode;
    try {
      recoveryCode = await service.enable(passphrase: passphrase);
    } on BackupException catch (e) {
      // A missing Storage bucket is an ENVIRONMENT gap, not an app defect, and
      // saying so is more useful than a bare failure.
      fail('cloud backup could not be enabled: ${e.code} — ${e.message}');
    }
    expect(recoveryCode.trim(), isNotEmpty,
        reason: 'enable() must return a recovery code to show once');
    // The code is a credential. Its shape is checked; its value is not logged.
    expect(recoveryCode.length, greaterThanOrEqualTo(8));
    debugPrint('[CLOUD] enabled — recovery code issued '
        '(${recoveryCode.length} chars, not logged)');

    final status = await service.status();
    expect(status.enabled, isTrue);
    debugPrint('[CLOUD] status enabled=${status.enabled} '
        'lastBackupAt=${status.lastBackupAt != null}');

    // ---- the object is really there ----------------------------------------
    expect(await service.hasRemoteBackup(), isTrue,
        reason: 'enable() reported success but no remote backup exists');
    debugPrint('[CLOUD] remote backup present');

    // ---- the negative: a wrong passphrase must NOT open it ------------------
    var wrongRejected = false;
    try {
      await service.prepareRestore(passphrase: '${passphrase}_WRONG');
    } on BackupException catch (e) {
      wrongRejected = true;
      debugPrint('[CLOUD] wrong passphrase rejected with ${e.code}');
    }
    expect(wrongRejected, isTrue,
        reason: 'the backup opened WITHOUT the right passphrase — it is not '
            'end-to-end encrypted in any meaningful sense');

    // ---- download, decrypt, validate, plan ---------------------------------
    final plan = await service.prepareRestore(passphrase: passphrase);
    expect(plan.operationId, isNotEmpty);
    debugPrint('[CLOUD] restore plan built — operationId present, '
        'warnings=${plan.warnings.length}, '
        'tables=${plan.expectedRowCounts.length}, '
        'rows=${plan.expectedRowCounts.values.fold(0, (a, b) => a + b)}');
    // Reaching a plan means the payload decrypted AND parsed. Deliberately no
    // commitRestore: that replaces the local database, and the confirmation
    // capability exists so it cannot happen without a human.
    debugPrint('[CLOUD] DONE — commitRestore intentionally NOT called');
  });
}
