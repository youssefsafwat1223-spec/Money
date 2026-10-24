import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/auth/account_deletion_gateway.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/settings/delete_account_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../core/session/fake_account_scope.dart';
import '../../core/session/fake_remove_barrier.dart';

class _Gateway implements AccountDeletionGateway {
  _Gateway({this.deletesImmediately = true});
  @override
  final bool deletesImmediately;
  final List<StreamController<AccountDeletionState>> runs = [];
  int get calls => runs.length;

  @override
  Stream<AccountDeletionState> delete() {
    final c = StreamController<AccountDeletionState>();
    runs.add(c);
    return c.stream;
  }
}

final _en = lookupAppL10n(const Locale('en'));

List<String> _wireRemoval() {
  FlutterSecureStorage.setMockInitialValues({'local_data_owner_uid': 'uid-x'});
  final calls = <String>[];
  final scope = FakeAccountScope(calls)..activeUid = 'uid-x';
  final support = Directory.systemTemp.createTempSync('del_');
  addTearDown(() => support.deleteSync(recursive: true));
  AppSession.instance.configureAccountScope(scope);
  AppSession.instance.configureRemoveData(RemoveDataFlow(
    store: ReplicaStore(appSupportDirectory: support.path),
    scope: scope,
    barrier: FakeRemoveBarrier(calls),
    clearOwnerMarker: AppSession.instance.clearLocalDataOwnerMarker,
    invalidateAdmissionGeneration:
        AppSession.instance.invalidateRemovalGeneration,
    quiesce: AppSession.instance.drainAdmissions,
  ));
  addTearDown(() {
    AppSession.instance.configureRemoveData(null);
    AppSession.instance.configureAccountScope(null);
  });
  return calls;
}

Widget _app(_Gateway gateway, {String locale = 'en'}) => ProviderScope(
      overrides: [accountDeletionGatewayProvider.overrideWithValue(gateway)],
      child: MaterialApp.router(
        theme: AppTheme.light,
        locale: Locale(locale),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: GoRouter(routes: [
          GoRoute(path: '/', builder: (_, __) => const DeleteAccountScreen()),
          GoRoute(path: '/welcome', builder: (_, __) => const SizedBox()),
        ]),
      ),
    );

Future<void> _startAndConfirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('deleteAccountAction')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('deleteAccountConfirm')));
  await tester.pump();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('one clear action; nothing runs on open', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deleteAccountAction')), findsOneWidget);
    expect(find.text(_en.deleteAccountAction), findsWidgets);
    expect(gateway.calls, 0);
  });

  testWidgets('the confirmation states it is permanent and immediate, and '
      'cancelling does nothing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await tester.tap(find.byKey(const Key('deleteAccountAction')));
    await tester.pumpAndSettle();
    expect(find.text(_en.deleteAccountConfirmBody), findsOneWidget);
    expect(_en.deleteAccountConfirmBody.toLowerCase(), contains('permanent'));
    expect(_en.deleteAccountConfirmBody.toLowerCase(), contains('immediate'));
    await tester.tap(find.text(_en.commonCancel));
    await tester.pumpAndSettle();
    expect(gateway.calls, 0);
    expect(find.byKey(const Key('deleteAccountProgress')), findsNothing);
  });

  testWidgets('in progress shows progress and no success, no navigation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final removal = _wireRemoval();
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await _startAndConfirm(tester);
    gateway.runs.single.add(const AccountDeletionInProgress());
    await tester.pump();
    expect(find.byKey(const Key('deleteAccountProgress')), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    expect(removal, isEmpty);
    expect(gateway.calls, 1);
    await gateway.runs.single.close();
  });

  testWidgets('accepted-but-not-completed is not success: it says so honestly '
      'and keeps the person and their local data where they are', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final removal = _wireRemoval();
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await _startAndConfirm(tester);
    gateway.runs.single
      ..add(const AccountDeletionInProgress())
      ..add(AccountDeletionAccepted(scheduledFor: DateTime.utc(2026, 11, 14)));
    await gateway.runs.single.close();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deleteAccountAccepted')), findsOneWidget);
    expect(find.text(_en.deleteAccountAcceptedBody), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    expect(removal, isEmpty, reason: 'no local reset before completion');
    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    // The honest copy never claims the account is already deleted.
    expect(_en.deleteAccountAcceptedBody.toLowerCase(),
        isNot(contains('has been deleted')));
  });

  testWidgets('completed shows success and only then resets and returns to '
      'the auth screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final removal = _wireRemoval();
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await _startAndConfirm(tester);
    gateway.runs.single.add(const AccountDeletionInProgress());
    await tester.pump();
    expect(removal, isEmpty);
    gateway.runs.single.add(const AccountDeletionCompleted());
    await gateway.runs.single.close();
    for (var i = 0; i < 500 && !removal.contains('finish:uid-x'); i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pump();
    expect(removal, contains('finish:uid-x'));
    expect(gateway.calls, 1);
  });

  testWidgets('a retryable failure shows an honest error with Retry that '
      'runs the gateway again; local data is untouched', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final removal = _wireRemoval();
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await _startAndConfirm(tester);
    gateway.runs.single.add(const AccountDeletionFailed(retryable: true));
    await gateway.runs.single.close();
    await tester.pumpAndSettle();
    expect(find.text(_en.deleteAccountFailed), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    expect(removal, isEmpty);
    await tester.tap(find.byKey(const Key('deleteAccountRetry')));
    await tester.pump();
    expect(gateway.calls, 2, reason: 'Retry runs the deletion again');
    gateway.runs.last.add(const AccountDeletionFailed(retryable: true));
    await gateway.runs.last.close();
    await tester.pumpAndSettle();
    expect(removal, isEmpty);
  });

  testWidgets('a non-retryable failure offers no Retry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await _startAndConfirm(tester);
    gateway.runs.single.add(const AccountDeletionFailed(retryable: false));
    await gateway.runs.single.close();
    await tester.pumpAndSettle();
    expect(find.text(_en.deleteAccountFailedFinal), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountRetry')), findsNothing);
  });

  testWidgets('a stream error is a failure, never success', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final removal = _wireRemoval();
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await _startAndConfirm(tester);
    gateway.runs.single.addError(StateError('boom'));
    await gateway.runs.single.close();
    await tester.pumpAndSettle();
    expect(find.text(_en.deleteAccountFailed), findsOneWidget);
    expect(removal, isEmpty);
  });

  testWidgets('a stream that ends while still in progress is not success',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final removal = _wireRemoval();
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway));
    await _startAndConfirm(tester);
    gateway.runs.single.add(const AccountDeletionInProgress());
    await gateway.runs.single.close();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deleteAccountSuccess')), findsNothing);
    expect(removal, isEmpty);
    expect(find.byKey(const Key('deleteAccountRetry')), findsOneWidget);
  });

  testWidgets('Arabic renders the same states', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ar = lookupAppL10n(const Locale('ar'));
    final gateway = _Gateway();
    await tester.pumpWidget(_app(gateway, locale: 'ar'));
    await tester.pumpAndSettle();
    expect(find.text(ar.deleteAccountAction), findsWidgets);
    await tester.tap(find.byKey(const Key('deleteAccountAction')));
    await tester.pumpAndSettle();
    expect(find.text(ar.deleteAccountConfirmBody), findsOneWidget);
  });

  for (final locale in ['en', 'ar']) {
    testWidgets('confirmation copy follows the gateway ($locale)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final l10n = lookupAppL10n(Locale(locale));
      for (final immediate in [true, false]) {
        await tester.pumpWidget(
            _app(_Gateway(deletesImmediately: immediate), locale: locale));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('deleteAccountAction')));
        await tester.pumpAndSettle();
        expect(
            find.text(immediate
                ? l10n.deleteAccountConfirmBody
                : l10n.deleteAccountConfirmBodyScheduled),
            findsOneWidget);
        expect(
            find.text(immediate
                ? l10n.deleteAccountConfirmBodyScheduled
                : l10n.deleteAccountConfirmBody),
            findsNothing);
        await tester.tap(find.byKey(const Key('deleteAccountConfirm')));
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
      }
    });
  }

  test('the scheduled copy makes no immediate claim', () {
    final en = lookupAppL10n(const Locale('en')).deleteAccountConfirmBodyScheduled;
    final ar = lookupAppL10n(const Locale('ar')).deleteAccountConfirmBodyScheduled;
    expect(en.toLowerCase(), isNot(contains('immediate')));
    expect(en.toLowerCase(), isNot(contains('right away')));
    expect(ar, isNot(contains('على الفور')));
    expect(ar, isNot(contains('فورًا')));
    expect(ar, isNot(contains('فورا')));
  });
}
