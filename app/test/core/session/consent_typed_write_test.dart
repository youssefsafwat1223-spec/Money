import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';

import '../../harness/consent_session_support.dart';
import 'f2_fixture.dart';

// Consent-security amendment: the TYPED consent transaction on a real per-uid
// Drift replica, driven by the real AppSession. The capability, database and
// replica owner are verified inside the transaction; a lifecycle that ends before
// the final synchronous check rolls back the settings AND the local outbox row; a
// choice authorized at that check may persist honestly even if COMMIT is still
// pending; the logout / readmission waits for it to settle.

class _Repo extends DriftUserSettingsRepository {
  _Repo(super.db, {super.outboxQueue, super.afterConsentFinalGuard});
  int reads = 0;
  int? _holdAtRead;
  Completer<void>? reached;
  Completer<void>? _release;

  void holdAtRead(int n) {
    _holdAtRead = n;
    reached = Completer<void>();
    _release = Completer<void>();
  }

  void release() => _release!.complete();

  @override
  Future<UserSettingsEntity> getSettings() async {
    final mine = ++reads;
    final value = await super.getSettings();
    if (mine == _holdAtRead && !reached!.isCompleted) {
      reached!.complete();
      await _release!.future;
    }
    return value;
  }
}

const _accept =
    ConsentChoices(cloud: ConsentState.accepted, ai: ConsentState.accepted);
const _decline =
    ConsentChoices(cloud: ConsentState.declined, ai: ConsentState.declined);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;

  setUp(() async {
    f = await F2Fixture.create();
  });

  tearDown(() async {
    await f.dispose();
  });

  Future<Object?> outcomeOf(Future<Object?> future) =>
      future.then<Object?>((_) => null, onError: (Object e) => e);

  group('merchant local preference transaction', () {
    Future<void> admit() async {
      await freshSignIn(f, 'uid-x');
      await f.signIn('uid-x');
    }

    void expectConsentUnchanged(
        UserSettingsEntity actual, UserSettingsEntity expected) {
      expect(actual.cloudConsentState, expected.cloudConsentState);
      expect(actual.aiConsentState, expected.aiConsentState);
      expect(actual.cloudConsentVersion, expected.cloudConsentVersion);
      expect(actual.aiConsentVersion, expected.aiConsentVersion);
      expect(actual.cloudConsentAt, expected.cloudConsentAt);
      expect(actual.aiConsentAt, expected.aiConsentAt);
    }

    Future<List<Map<String, dynamic>>> rawRows(
            AppDatabase db, String table) async =>
        (await db.customSelect('SELECT * FROM $table ORDER BY id;').get())
            .map((row) => Map<String, dynamic>.from(row.data))
            .toList();

    test(
        'merchant rejects zero settings rows without creating defaults or outbox',
        () async {
      await admit();
      final db = f.host.current!.database;
      final authority = f.session.captureLocalWorkAuthority()!;
      final repo = DriftUserSettingsRepository(db);
      await db.customStatement('DELETE FROM user_settings;');
      final outbox = await rawRows(db, 'planning_sync_outbox');
      final outcome = await outcomeOf(f.session.runAdmittedLocalOperation(
          authority,
          () => repo.saveMerchantPersonalization(authority, db, true)));
      expect(await rawRows(db, 'user_settings'), isEmpty);
      expect(await rawRows(db, 'planning_sync_outbox'), outbox);
      expect(outcome, isA<StateError>());
    });

    test('merchant rejects two settings rows without modifying either row',
        () async {
      await admit();
      final db = f.host.current!.database;
      final authority = f.session.captureLocalWorkAuthority()!;
      final repo = DriftUserSettingsRepository(db);
      await repo.saveConsentChoice(
          f.session.captureConsentCapability()!, _accept);
      final schema =
          await db.customSelect('PRAGMA table_info(user_settings);').get();
      final columns = schema.map((row) => row.read<String>('name')).toList();
      // Test-only schema-derived clone includes every actual persisted column.
      String quote(String name) => '"${name.replaceAll('"', '""')}"';
      final names = columns.map(quote).join(', ');
      final values = columns
          .map((name) =>
              name == 'id' ? "'merchant-second-settings'" : quote(name))
          .join(', ');
      await db.customStatement(
          'INSERT INTO user_settings ($names) SELECT $values FROM user_settings;');
      await db.customStatement("UPDATE user_settings SET "
          "merchant_personalization_enabled = 1, cloud_consent_state = 'declined', "
          "ai_consent_state = 'declined', cloud_consent_version = 37, "
          "ai_consent_version = 41, cloud_consent_at = 1234, ai_consent_at = 5678 "
          "WHERE id = 'merchant-second-settings';");
      final before = await rawRows(db, 'user_settings');
      expect(before, hasLength(2));
      final outbox = await rawRows(db, 'planning_sync_outbox');
      final outcome = await outcomeOf(f.session.runAdmittedLocalOperation(
          authority,
          () => repo.saveMerchantPersonalization(authority, db, false)));
      expect(await rawRows(db, 'user_settings'), before);
      expect(await rawRows(db, 'planning_sync_outbox'), outbox);
      expect(outcome, isA<StateError>());
    });

    test('merchant updates exactly one settings ID and preserves other columns',
        () async {
      await admit();
      final db = f.host.current!.database;
      final authority = f.session.captureLocalWorkAuthority()!;
      final repo = DriftUserSettingsRepository(db);
      await repo.saveConsentChoice(
          f.session.captureConsentCapability()!,
          const ConsentChoices(
              cloud: ConsentState.accepted, ai: ConsentState.declined));
      final before = await rawRows(db, 'user_settings');
      expect(before, hasLength(1));
      final expected = Map<String, dynamic>.from(before.single);
      final enabled = expected['merchant_personalization_enabled'] != 1;
      expected['merchant_personalization_enabled'] = enabled ? 1 : 0;
      final outbox = await rawRows(db, 'planning_sync_outbox');
      await f.session.runAdmittedLocalOperation(authority,
          () => repo.saveMerchantPersonalization(authority, db, enabled));
      expect(await rawRows(db, 'user_settings'), [expected]);
      expect(await rawRows(db, 'planning_sync_outbox'), outbox);
    });

    for (final suppress in [true, false]) {
      test(
          suppress
              ? 'merchant rolls back when SQL suppresses its single-row update'
              : 'merchant storage error rolls back without outbox', () async {
        await admit();
        final db = f.host.current!.database;
        final authority = f.session.captureLocalWorkAuthority()!;
        final repo = DriftUserSettingsRepository(db);
        final before = await rawRows(db, 'user_settings');
        final outbox = await rawRows(db, 'planning_sync_outbox');
        await db.customStatement('CREATE TRIGGER merchant_test_reject '
            'BEFORE UPDATE OF merchant_personalization_enabled ON user_settings '
            'BEGIN SELECT ${suppress ? "RAISE(IGNORE)" : "RAISE(ABORT, 'merchant_test_storage_failure')"}; END;');
        final outcome = await outcomeOf(f.session.runAdmittedLocalOperation(
            authority,
            () => repo.saveMerchantPersonalization(authority, db,
                before.single['merchant_personalization_enabled'] != 1)));
        expect(await rawRows(db, 'user_settings'), before);
        expect(await rawRows(db, 'planning_sync_outbox'), outbox);
        if (suppress) {
          expect(outcome, isA<StateError>());
        } else {
          expect(outcome, isNotNull);
          expect(outcome.toString(), contains('merchant_test_storage_failure'));
        }
      });
    }

    test('decline queued while merchant SQL is paused keeps both denials',
        () async {
      await admit();
      final db = f.host.current!.database;
      final authority = f.session.captureLocalWorkAuthority()!;
      final cap = f.session.captureConsentCapability()!;
      final reached = Completer<void>();
      final release = Completer<void>();
      final queue = HookedOutbox(db, 'uid-x');
      final repo = DriftUserSettingsRepository(db, outboxQueue: queue,
          beforeMerchantUpdate: () async {
        reached.complete();
        await release.future;
      });
      await repo.saveConsentChoice(cap, _accept);
      final merchant = f.session.runAdmittedLocalOperation(authority,
          () => repo.saveMerchantPersonalization(authority, db, true));
      await reached.future;
      final decline = f.session.runConsentLocalOperation(
          cap, () => repo.saveConsentChoice(cap, _decline));
      release.complete();
      await merchant;
      final denied = await decline;
      final stored = await repo.getSettings();
      expect(stored.merchantPersonalizationEnabled, isTrue);
      expectConsentUnchanged(stored, denied);
      expect(stored.cloudConsentState, ConsentState.declined);
      expect(stored.aiConsentState, ConsentState.declined);
      expect(queue.enqueues, 2, reason: 'merchant enqueues nothing');
    });

    test('merchant queued behind a paused decline preserves its versions/times',
        () async {
      await admit();
      final db = f.host.current!.database;
      final authority = f.session.captureLocalWorkAuthority()!;
      final cap = f.session.captureConsentCapability()!;
      final queue = HookedOutbox(db, 'uid-x');
      final repo = _Repo(db, outboxQueue: queue);
      await repo.saveConsentChoice(cap, _accept);
      repo.holdAtRead(repo.reads + 1);
      final decline = f.session.runConsentLocalOperation(
          cap, () => repo.saveConsentChoice(cap, _decline));
      await repo.reached!.future;
      final merchant = f.session.runAdmittedLocalOperation(authority,
          () => repo.saveMerchantPersonalization(authority, db, true));
      repo.release();
      final denied = await decline;
      await merchant;
      final stored = await repo.getSettings();
      expectConsentUnchanged(stored, denied);
      expect(stored.merchantPersonalizationEnabled, isTrue);
      expect(queue.enqueues, 2);
    });

    test('logout after merchant SQL rolls back and local drain settles',
        () async {
      await admit();
      final db = f.host.current!.database;
      final authority = f.session.captureLocalWorkAuthority()!;
      final reached = Completer<void>();
      final release = Completer<void>();
      final repo =
          DriftUserSettingsRepository(db, afterMerchantUpdate: () async {
        reached.complete();
        await release.future;
      });
      final before = await repo.getSettings();
      final pending = outcomeOf(f.session.runAdmittedLocalOperation(
          authority,
          () => repo.saveMerchantPersonalization(
              authority, db, !before.merchantPersonalizationEnabled)));
      await reached.future;
      final logout = f.session.signOut();
      expect(authority.isCurrent, isFalse);
      release.complete();
      expect(await pending, isA<StaleAdmissionException>());
      await logout;
      await f.signIn('uid-x');
      final stored = await DriftUserSettingsRepository(f.host.current!.database)
          .getSettings();
      expect(stored.merchantPersonalizationEnabled,
          before.merchantPersonalizationEnabled);
      expectConsentUnchanged(stored, before);
    });

    test('null, other database and wrong owner fail closed', () async {
      await admit();
      final db = f.host.current!.database;
      final repo = DriftUserSettingsRepository(db);
      final authority = f.session.captureLocalWorkAuthority()!;
      await expectLater(repo.saveMerchantPersonalization(authority, null, true),
          throwsA(isA<StaleAdmissionException>()));
      final other = await AppDatabase.open(executor: NativeDatabase.memory());
      addTearDown(other.close);
      await expectLater(
          repo.saveMerchantPersonalization(authority, other, true),
          throwsA(isA<StaleAdmissionException>()));
      await expectLater(
          repo.saveMerchantPersonalization(
              const AdmissionAuthority.forTest('other'), db, true),
          throwsA(isA<StaleAdmissionException>()));
    });

    test('closed database and authority from a prior admission are rejected',
        () async {
      await admit();
      final db = f.host.current!.database;
      final authority = f.session.captureLocalWorkAuthority()!;
      final retained = DriftUserSettingsRepository(db);
      await f.session.signOut();
      await f.signIn('uid-x');
      await expectLater(
          retained.saveMerchantPersonalization(authority, db, true),
          throwsA(isA<StaleAdmissionException>()));
      final closed = await AppDatabase.open(executor: NativeDatabase.memory());
      final closedWriter = DriftUserSettingsRepository(closed);
      await closed.close();
      await expectLater(
          closedWriter.saveMerchantPersonalization(
              f.session.captureLocalWorkAuthority()!, closed, true),
          throwsA(isA<StaleAdmissionException>()));
    });

    test('first onboarding has no ordinary local authority', () async {
      expect(await freshSignIn(f, 'uid-x'), isNotNull);
      expect(f.session.captureLocalWorkAuthority(), isNull);
    });
  });

  group('a fresh committed identity (needsOnboarding)', () {
    test(
        'accept persists once through the typed writer, with the local outbox '
        'row in the same transaction', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      expect(f.session.status, SessionStatus.needsOnboarding);
      final db = f.host.current!.database;
      final repo = _Repo(db, outboxQueue: HookedOutbox(db, 'uid-x'));
      final rows = await settingsOutboxRows(db);
      final saved = await f.session.runConsentLocalOperation(
          cap, () => repo.saveConsentChoice(cap, _accept));
      expect(saved.cloudConsentState, ConsentState.accepted);
      expect(saved.aiConsentState, ConsentState.accepted);
      final stored = await repo.getSettings();
      expect(stored.cloudConsentState, ConsentState.accepted);
      expect(stored.aiConsentState, ConsentState.accepted);
      expect(stored.cloudConsentVersion, greaterThan(0),
          reason: 'the existing version assignment is preserved');
      expect(await settingsOutboxRows(db), rows + 1);
    });

    test('decline persists both denials', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final db = f.host.current!.database;
      final repo = _Repo(db, outboxQueue: HookedOutbox(db, 'uid-x'));
      await f.session.runConsentLocalOperation(
          cap, () => repo.saveConsentChoice(cap, _decline));
      final stored = await repo.getSettings();
      expect(stored.cloudConsentState, ConsentState.declined);
      expect(stored.aiConsentState, ConsentState.declined);
    });

    test(
        'only the consent choices are merged into the CURRENT row: another '
        'setting changed meanwhile is neither carried nor overwritten',
        () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final db = f.host.current!.database;
      final repo = _Repo(db);
      final before = await repo.getSettings();
      final otherTheme = before.theme == 'dark' ? 'light' : 'dark';
      await repo.saveSettings(before.copyWith(theme: otherTheme));
      await repo.saveConsentChoice(
          cap, const ConsentChoices(cloud: ConsentState.accepted));
      final stored = await repo.getSettings();
      expect(stored.cloudConsentState, ConsentState.accepted);
      expect(stored.aiConsentState, ConsentState.unset,
          reason: 'a null choice leaves the stored value untouched');
      expect(stored.theme, otherTheme);
    });

    test(
        'a changed-only choice leaves the OTHER consent and its version '
        'alone, whatever a stale snapshot said', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final db = f.host.current!.database;
      final repo = _Repo(db);
      // The user's open screen was built when nothing was chosen (stale)...
      final stale = await repo.getSettings();
      expect(stale.cloudConsentState, ConsentState.unset);
      // ...meanwhile the cloud decision was declined elsewhere.
      await repo.saveConsentChoice(
          cap, const ConsentChoices(cloud: ConsentState.declined));
      final afterCloud = await repo.getSettings();
      // The AI switch of the stale screen passes ONLY its own choice.
      await repo.saveConsentChoice(
          cap, const ConsentChoices(ai: ConsentState.accepted));
      final stored = await repo.getSettings();
      expect(stored.aiConsentState, ConsentState.accepted);
      expect(stored.cloudConsentState, ConsentState.declined,
          reason: 'the cloud denial is not cleared by an AI-only toggle');
      expect(stored.cloudConsentVersion, afterCloud.cloudConsentVersion);
      expect(stored.cloudConsentAt, afterCloud.cloudConsentAt);
      expect(stored.aiConsentVersion, greaterThan(afterCloud.consentVersion));

      // And the other way round: a cloud-only choice never overwrites the AI one.
      await repo.saveConsentChoice(
          cap, const ConsentChoices(cloud: ConsentState.accepted));
      final both = await repo.getSettings();
      expect(both.cloudConsentState, ConsentState.accepted);
      expect(both.aiConsentState, ConsentState.accepted);
      expect(both.aiConsentVersion, stored.aiConsentVersion);
      expect(both.cloudConsentVersion, greaterThan(stored.cloudConsentVersion));
    });

    test(
        'the merchant preference merged into the current row changes neither '
        'consent nor any consent version', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final db = f.host.current!.database;
      final repo = _Repo(db);
      await repo.saveConsentChoice(cap, _accept);
      final before = await repo.getSettings();
      await repo.saveSettings((await repo.getSettings())
          .copyWith(merchantPersonalizationEnabled: true));
      final after = await repo.getSettings();
      expect(after.merchantPersonalizationEnabled, isTrue);
      expect(after.cloudConsentState, before.cloudConsentState);
      expect(after.aiConsentState, before.aiConsentState);
      expect(after.cloudConsentVersion, before.cloudConsentVersion);
      expect(after.aiConsentVersion, before.aiConsentVersion);
      expect(after.cloudConsentAt, before.cloudConsentAt);
      expect(after.aiConsentAt, before.aiConsentAt);
    });
  });

  group('refused inside the transaction, nothing written', () {
    test(
        'a capability of another owner, another database, or an ended '
        'lifecycle', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final db = f.host.current!.database;
      final outbox = HookedOutbox(db, 'uid-x');
      final repo = _Repo(db, outboxQueue: outbox);
      final rows = await settingsOutboxRows(db);
      final other = await AppDatabase.open(executor: NativeDatabase.memory());
      addTearDown(other.close);
      final wrongOwner = ConsentCapability(
          uid: 'uid-other',
          epoch: cap.epoch,
          database: db,
          isCurrent: () => true);
      final wrongDatabase = ConsentCapability(
          uid: 'uid-x',
          epoch: cap.epoch,
          database: other,
          isCurrent: () => true);
      final ended = ConsentCapability(
          uid: 'uid-x', epoch: cap.epoch, database: db, isCurrent: () => false);
      for (final bad in [wrongOwner, wrongDatabase, ended]) {
        await expectLater(repo.saveConsentChoice(bad, _accept),
            throwsA(isA<StaleAdmissionException>()));
      }
      final stored = await repo.getSettings();
      expect(stored.cloudConsentState, ConsentState.unset);
      expect(stored.aiConsentState, ConsentState.unset);
      expect(await settingsOutboxRows(db), rows);
      expect(outbox.enqueues, 0);
    });

    test(
        'an old capability after the logout settled: stale WITHOUT touching '
        'the closed database', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final db = f.host.current!.database;
      final repo = _Repo(db);
      await f.session.signOut();
      expect(db.lifecycleState, isNot(DatabaseLifecycleState.open));
      await expectLater(repo.saveConsentChoice(cap, _accept),
          throwsA(isA<StaleAdmissionException>()));
      expect(repo.reads, 0, reason: 'no closed-database access');
    });
  });

  group('the linearization points', () {
    test(
        'revoked after the SQL and the outbox, before the final guard: the '
        'settings AND the outbox row roll back', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final db = f.host.current!.database;
      var live = true;
      final revokable = ConsentCapability(
          uid: 'uid-x',
          epoch: cap.epoch,
          database: db,
          isCurrent: () => live && cap.isCurrent);
      final outbox =
          HookedOutbox(db, 'uid-x', afterEnqueue: () => live = false);
      final repo = _Repo(db, outboxQueue: outbox);
      final rows = await settingsOutboxRows(db);
      final before = await repo.getSettings();
      await expectLater(repo.saveConsentChoice(revokable, _accept),
          throwsA(isA<StaleAdmissionException>()));
      expect(outbox.enqueues, 1, reason: 'the SQL and the enqueue DID run');
      final stored = await repo.getSettings();
      expect(stored.cloudConsentState, ConsentState.unset);
      expect(stored.aiConsentState, ConsentState.unset);
      expect(stored.cloudConsentVersion, before.cloudConsentVersion);
      expect(stored.aiConsentVersion, before.aiConsentVersion);
      expect(await settingsOutboxRows(db), rows,
          reason: 'the outbox row was rolled back with the settings');
    });

    test(
        'a logout accepted between the final guard and COMMIT: it waits for '
        'the settlement, the authorized choice persists honestly', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final db = f.host.current!.database;
      Future<void>? logout;
      final repo = _Repo(db,
          outboxQueue: HookedOutbox(db, 'uid-x'),
          afterConsentFinalGuard: () => logout = f.session.signOut());
      final saved = await f.session.runConsentLocalOperation(
          cap, () => repo.saveConsentChoice(cap, _accept));
      expect(saved.cloudConsentState, ConsentState.accepted);
      expect(cap.isCurrent, isFalse, reason: 'revoked right after the guard');
      await logout;
      expect(f.scope.calls, contains('lock'));
      // The legitimate local persistence is there when the uid comes back; no
      // rollback after COMMIT is promised or performed.
      expect(await freshSignIn(f, 'uid-x'), isNotNull);
      final newDb = f.host.current!.database;
      final stored = await DriftUserSettingsRepository(newDb).getSettings();
      expect(stored.cloudConsentState, ConsentState.accepted);
      expect(stored.aiConsentState, ConsentState.accepted);
      expect(await settingsOutboxRows(newDb), 1);
    });

    test(
        'held BEFORE the write, then the same uid is readmitted: the transition '
        'is started without awaiting, the old proof is invalid at once, and the '
        'newer scope keeps its consent UNSET', () async {
      final cap = (await freshSignIn(f, 'uid-x'))!;
      final sdk = await F2Fixture.liveClient('uid-x');
      final db = f.host.current!.database;
      final repo = _Repo(db, outboxQueue: HookedOutbox(db, 'uid-x'));
      repo.holdAtRead(1); // inside the transaction, before anything is written
      final op = outcomeOf(f.session.runConsentLocalOperation(
          cap, () => repo.saveConsentChoice(cap, _accept)));
      await repo.reached!.future;

      var readmitted = false;
      final readmission = freshSignIn(f, 'uid-x', client: sdk)
          .whenComplete(() => readmitted = true);
      expect(cap.isCurrent, isFalse);
      expect(f.session.captureConsentCapability(), isNull);
      expect(f.session.captureLocalWorkAuthority(), isNull);
      await pumpEventQueue(times: 40);
      expect(readmitted, isFalse,
          reason: 'the readmission waits for the held operation');

      repo.release();
      expect(await op, isA<StaleAdmissionException>(),
          reason: 'the held write was not committed');
      final next = await readmission;
      expect(next, isNotNull);
      final newDb = f.host.current!.database;
      final stored = await DriftUserSettingsRepository(newDb).getSettings();
      expect(stored.cloudConsentState, ConsentState.unset,
          reason: 'the newer consent was never written by the old proof');
      expect(stored.aiConsentState, ConsentState.unset);
      expect(await settingsOutboxRows(newDb), 0);
    });
  });

  test(
      'the bounded runner does no network work: the typed write completes '
      'without any client in scope', () async {
    // The runner only awaits the supplied local action; nothing in this file
    // constructs a network client or a socket, and the SDK session is the
    // MockClient-backed fake GoTrue client.
    final cap = (await freshSignIn(f, 'uid-x'))!;
    final db = f.host.current!.database;
    final repo = _Repo(db);
    final saved = await f.session.runConsentLocalOperation(
        cap, () => repo.saveConsentChoice(cap, _accept));
    expect(saved.cloudConsentState, ConsentState.accepted);
  });
}
