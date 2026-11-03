// Offline QA only. Mount the overlay beside, never inside, the app Navigator.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/account_access_mode.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/card_form_sheet.dart';

const visualParityCardOutcomeKeys = <String>[
  'cardFormSaving',
  'cardFormSaveError',
  'cardFormDeleting',
  'cardFormDeleteError',
];
final visualParityCardOutcomeOverlay = ValueNotifier<Widget?>(null);
final _events = <String, int>{};
Map<String, int> visualParityCardOutcomeEvents() => Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
_CardFixture? _active;
BuildContext? get visualParityCardOutcomeInspectionContext =>
    _active?.navigator.currentContext;
const _accountId = 'qa-card-outcome-account';
const _cardId = 'qa-card-outcome-card';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'card-outcome-owned-memory';
  @override
  Future<String?> readStoredKey() async => 'card-outcome-owned-memory';
}

class _CardOutcomeRepository extends DriftCardRepository {
  _CardOutcomeRepository(super.database, this.key);
  final String key;
  Completer<CardEntity>? heldUpdate;
  Completer<void>? heldDelete;

  Never _forbidden() {
    _event('cardOutcomeForbiddenWrite');
    throw StateError('card_outcome_unexpected_write');
  }

  @override
  Future<CardEntity> update(CardEntity card) {
    if (!key.startsWith('cardFormSav') ||
        card.id != _cardId ||
        card.accountId != _accountId ||
        card.last4 != '4521' ||
        card.network != CardNetwork.visa ||
        card.source != CardSource.manual ||
        card.nickname != 'QA revised card') {
      return _forbidden();
    }
    _event(key);
    if (key.endsWith('Saving')) {
      heldUpdate = Completer<CardEntity>();
      return heldUpdate!.future;
    }
    return Future<CardEntity>.error(StateError('private_card_update_failure'));
  }

  @override
  Future<void> delete(String id) {
    if (!key.startsWith('cardFormDelet') || id != _cardId) return _forbidden();
    _event(key);
    if (key.endsWith('Deleting')) {
      heldDelete = Completer<void>();
      return heldDelete!.future;
    }
    return Future<void>.error(StateError('private_card_delete_failure'));
  }

  @override
  Future<CardEntity> create(CardEntity card) => _forbidden();
  @override
  Future<CardEntity> moveToAccount(
          {required String cardId, required String newAccountId}) =>
      _forbidden();
  @override
  Future<int> backfillFromTransactions() => _forbidden();

  void cancelPending() {
    if (heldUpdate case final pending? when !pending.isCompleted) {
      pending.completeError(StateError('card_visual_fixture_closed'));
    }
    if (heldDelete case final pending? when !pending.isCompleted) {
      pending.completeError(StateError('card_visual_fixture_closed'));
    }
  }
}

Future<bool> openVisualParityCardOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityCardOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('card_outcome_requires_offline_debug');
  }
  if (ref.read(accountAccessModeProvider) != AccountAccessMode.writable) {
    throw StateError('card_outcome_requires_writable_memory_parent');
  }
  final rows = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!rows.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('card_outcome_requires_memory_parent');
  }
  if (!context.mounted) return false;
  if (_active != null) throw StateError('card_outcome_already_open');
  final locale = Localizations.localeOf(context);
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? child;
  try {
    final at = DateTime.utc(2026, 11, 1);
    await DriftAccountRepository(db).create(AccountEntity(
        id: _accountId,
        name: 'QA card account',
        currency: 'KWD',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        createdAt: at,
        updatedAt: at,
        initialBalanceMoney: Money.zero('KWD'),
        currentBalanceMoney: Money.zero('KWD')));
    final setup = DriftCardRepository(db);
    await setup.create(CardEntity(
        id: _cardId,
        accountId: _accountId,
        last4: '4521',
        network: CardNetwork.visa,
        source: CardSource.manual,
        nickname: 'QA card',
        createdAt: at,
        updatedAt: at));
    final card = (await setup.getById(_cardId))!;
    final repository = _CardOutcomeRepository(db, key);
    child = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
      cardRepositoryProvider.overrideWithValue(repository),
    ]);
    if (!context.mounted) {
      child.dispose();
      await db.close();
      return false;
    }
    final fixture = _CardFixture(db, child, repository, card, key);
    _active = fixture;
    _event('${key}Opened');
    visualParityCardOutcomeOverlay.value = _CardHost(fixture);
    return true;
  } catch (_) {
    child?.dispose();
    await db.close();
    rethrow;
  }
}

Future<void> closeVisualParityCardOutcome() {
  final fixture = _active;
  if (fixture == null) return Future<void>.value();
  final navigator = fixture.navigator.currentState;
  navigator?.popUntil((route) => route.isFirst);
  fixture.requestClose();
  return fixture.closed.future;
}

class _CardFixture {
  _CardFixture(this.db, this.container, this.repository, this.card, this.key);
  final AppDatabase db;
  final ProviderContainer container;
  final _CardOutcomeRepository repository;
  final CardEntity card;
  final String key;
  final navigator = GlobalKey<NavigatorState>();
  final closed = Completer<void>();
  bool mounted = false;
  bool disposing = false;

  void requestClose() {
    if (identical(_active, this)) visualParityCardOutcomeOverlay.value = null;
    if (!mounted) unawaited(disposeOnce());
  }

  Future<void> disposeOnce() async {
    if (disposing) return;
    disposing = true;
    repository.cancelPending();
    container.dispose();
    await db.close();
    if (identical(_active, this)) _active = null;
    _event('${key}Closed');
    closed.complete();
  }
}

class _CardHost extends StatefulWidget {
  const _CardHost(this.fixture);
  final _CardFixture fixture;
  @override
  State<_CardHost> createState() => _CardHostState();
}

class _CardHostState extends State<_CardHost> {
  @override
  void initState() {
    super.initState();
    widget.fixture.mounted = true;
  }

  @override
  void dispose() {
    widget.fixture.mounted = false;
    unawaited(widget.fixture.disposeOnce());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
      container: widget.fixture.container,
      child: HeroControllerScope.none(
          child: Navigator(
              key: widget.fixture.navigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => _CardLaunch(widget.fixture)))));
}

class _CardLaunch extends ConsumerStatefulWidget {
  const _CardLaunch(this.fixture);
  final _CardFixture fixture;
  @override
  ConsumerState<_CardLaunch> createState() => _CardLaunchState();
}

class _CardLaunchState extends ConsumerState<_CardLaunch> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await showCardForm(context, ref,
            accountId: widget.fixture.card.accountId,
            card: widget.fixture.card);
      } finally {
        widget.fixture.requestClose();
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
