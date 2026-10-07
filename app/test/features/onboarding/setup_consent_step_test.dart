import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';

import '../consent/consent_test_harness.dart';

/// In-memory account repository that records every create call (the spy).
class SpyAccountRepo implements AccountRepository {
  final List<AccountEntity> accounts = [];
  final List<AccountEntity> createCalls = [];
  bool failNextCreate = false;

  @override
  Future<List<AccountEntity>> getAll() async => List.of(accounts);
  @override
  Future<AccountEntity?> getById(String id) async =>
      accounts.where((a) => a.id == id).firstOrNull;
  @override
  Future<AccountEntity?> getDefault() async => accounts.firstOrNull;
  @override
  Future<AccountEntity> create(AccountEntity account) async {
    createCalls.add(account);
    if (failNextCreate) {
      failNextCreate = false;
      throw StateError('disk');
    }
    // Idempotent on id, like the real primary key.
    accounts.removeWhere((a) => a.id == account.id);
    accounts.add(account);
    return account;
  }

  @override
  Future<AccountEntity> update(AccountEntity account) async => account;
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> setDefault(String id) async {}
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  late SpyAccountRepo accountRepo;

  Future<void> advance(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  Future<void> pumpSetup(
    WidgetTester tester, {
    OnboardingSetupEntry entry = OnboardingSetupEntry.full,
    String country = 'Egypt',
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        saveCountryCurrencyUseCaseProvider.overrideWithValue(_OkSaveCountry()),
        accountRepositoryProvider.overrideWithValue(accountRepo),
        accountsProvider
            .overrideWith((ref) => ref.watch(accountRepositoryProvider).getAll()),
      ],
      home: OnboardingSetupScreen(entry: entry),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    if (entry == OnboardingSetupEntry.full) {
      expect(find.text('Step 1 of 7'), findsOneWidget);
      await tester.tap(find.textContaining(country).first);
      await advance(tester);
    }
  }

  setUp(() => accountRepo = SpyAccountRepo());

  testWidgets('steps run in the specified order, nothing is pre-selected',
      (tester) async {
    await pumpSetup(tester);
    expect(find.text('Step 2 of 7'), findsOneWidget);
    expect(find.text('Cloud Sync'), findsOneWidget);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    await tester.tap(find.text('Not now'));
    await advance(tester);

    expect(find.text('Step 3 of 7'), findsOneWidget);
    expect(find.text('Smart Analysis'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await advance(tester);

    expect(find.text('Step 4 of 7'), findsOneWidget);
    expect(find.text('Connection status'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await advance(tester);

    expect(find.text('Step 5 of 7'), findsOneWidget);
    expect(find.text('Set up your account'), findsOneWidget);
    // Not yet done: the Start button is disabled and no account exists.
    expect(accountRepo.accounts, isEmpty);
    expect(repo.saveCalls, 0, reason: '"Not now" writes nothing');
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.retryCalls, 0);
  });

  testWidgets('Cloud Sync: Enable grants cloud ONLY; AI stays unset',
      (tester) async {
    await pumpSetup(tester);
    await tester.tap(find.text('Enable Cloud Sync'));
    await advance(tester);
    expect(repo.settings.cloudConsentState, ConsentState.accepted);
    expect(repo.settings.aiConsentState, ConsentState.unset);

    // AI step with cloud ON: disclosure only, no dependency notice.
    expect(find.text('Step 3 of 7'), findsOneWidget);
    expect(find.text('Enable Smart Analysis'), findsOneWidget);
    expect(find.textContaining('requires Cloud Sync'), findsNothing);
    await tester.tap(find.text('Enable Smart Analysis'));
    await advance(tester);
    expect(repo.settings.aiConsentState, ConsentState.accepted);
    expect(service.retryCalls, 1);
  });

  testWidgets('Smart Analysis with cloud OFF only explains the dependency: '
      'no grant is offered, so cloud and AI are never granted together',
      (tester) async {
    await pumpSetup(tester);
    await tester.tap(find.text('Not now'));
    await advance(tester);

    expect(find.text('Turn on Cloud Sync first to use Smart Analysis.'),
        findsOneWidget);
    expect(find.text('Enable Smart Analysis'), findsNothing);
    expect(find.text('Enable Cloud Sync and Smart Analysis'), findsNothing);
    expect(find.text('Enable Cloud Sync'), findsNothing);
    // The skip control still lets the user move on, writing nothing.
    await tester.tap(find.text('Not now'));
    await advance(tester);
    expect(find.text('Step 4 of 7'), findsOneWidget);
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
  });

  testWidgets('readiness shows live status and a failure never blocks',
      (tester) async {
    await pumpSetup(tester);
    service.outcome = const CaptureRegistrationStatus(
        CaptureRegistrationPhase.failed, 'register_failed');
    await tester.tap(find.text('Enable Cloud Sync'));
    await advance(tester);
    await tester.tap(find.text('Enable Smart Analysis'));
    await advance(tester);

    expect(find.text('Step 4 of 7'), findsOneWidget);
    expect(find.textContaining("isn't connected"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await advance(tester);
    expect(find.text('Step 5 of 7'), findsOneWidget);
  });

  testWidgets('Account Setup: name is required, currency defaults to the '
      'country currency, no default name', (tester) async {
    await pumpSetup(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Not now'));
      await advance(tester);
    }
    await tester.tap(find.text('Continue'));
    await advance(tester);

    final nameField = tester.widget<TextField>(
        find.byKey(const ValueKey('account-name-field')));
    expect(nameField.controller!.text, isEmpty);
    expect(find.textContaining('EGP'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('account-save-button')));
    await tester.pump();
    expect(find.text('Please enter an account name'), findsOneWidget);
    expect(accountRepo.createCalls, isEmpty);
  });

  testWidgets('Account Setup: create goes through the repository, a failed '
      'save retries with the SAME id, then the step completes',
      (tester) async {
    await pumpSetup(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Not now'));
      await advance(tester);
    }
    await tester.tap(find.text('Continue'));
    await advance(tester);

    await tester.enterText(
        find.byKey(const ValueKey('account-name-field')), 'My bank');
    accountRepo.failNextCreate = true;
    await tester.tap(find.byKey(const ValueKey('account-save-button')));
    await tester.pumpAndSettle();
    expect(accountRepo.accounts, isEmpty);
    expect(find.text('Step 5 of 7'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-save-button')));
    await advance(tester);
    expect(accountRepo.createCalls, hasLength(2));
    expect(accountRepo.createCalls[0].id, accountRepo.createCalls[1].id,
        reason: 'retry must reuse the creation id (no duplicate)');
    expect(accountRepo.accounts, hasLength(1));
    expect(accountRepo.accounts.single.name, 'My bank');
    expect(accountRepo.accounts.single.currency, 'EGP');
    expect(accountRepo.accounts.single.type, AccountType.bank);
    expect(find.text('Step 6 of 7'), findsOneWidget);
  });

  testWidgets('an existing account is shown; user may continue or add another',
      (tester) async {
    final now = DateTime.utc(2026, 1, 1);
    accountRepo.accounts.add(AccountEntity(
      id: 'default_account',
      name: 'Legacy main',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    ));
    await pumpSetup(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Not now'));
      await advance(tester);
    }
    await tester.tap(find.text('Continue'));
    await advance(tester);

    expect(find.text('Legacy main'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-account-add-another')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('account-name-field')), findsOneWidget);
    expect(accountRepo.createCalls, isEmpty);
  });

  testWidgets('finish is blocked without an account', (tester) async {
    await pumpSetup(tester, entry: OnboardingSetupEntry.captureGuide);
    await tester.tap(find.text('Installed'));
    await advance(tester);
    expect(accountRepo.accounts, isEmpty);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Add an account to finish setup.'), findsOneWidget);
    expect(find.text('Step 5 of 7'), findsOneWidget,
        reason: 'sent back to Account Setup');
  });
}

class _OkSaveCountry extends FakeSaveCountry {
  @override
  Future<UserSettingsEntity> call(String country, String currency) async =>
      FakeSettingsRepository().settings;
}
