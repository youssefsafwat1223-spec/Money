import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/account_deletion_service.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';

class _FakeAccountDeletionService implements AccountDeletionService {
  _FakeAccountDeletionService({this.scheduledAt, this.throwOnRequest = false});

  DateTime? scheduledAt;
  bool throwOnRequest;
  var requestCalls = 0;
  var cancelCalls = 0;

  @override
  Future<AccountDeletionStatus> getStatus() async {
    return AccountDeletionStatus(scheduledAt: scheduledAt);
  }

  @override
  Future<DateTime?> requestDeletion() async {
    requestCalls += 1;
    if (throwOnRequest) throw Exception('boom');
    scheduledAt = DateTime.now().toUtc().add(const Duration(days: 30));
    return scheduledAt;
  }

  @override
  Future<void> cancelDeletion() async {
    cancelCalls += 1;
    scheduledAt = null;
  }
}

class _NoopDataWipeService implements DataWipeService {
  var wipeCalls = 0;

  @override
  Future<void> wipeAll() async {
    wipeCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(_FakeAccountDeletionService service, _NoopDataWipeService wipe) {
  return ProviderScope(
    overrides: [
      accountDeletionServiceProvider.overrideWithValue(service),
      accountDeletionStatusProvider.overrideWith((_) => service.getStatus()),
      dataWipeServiceProvider.overrideWithValue(wipe),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: const PrivacyScreen(),
    ),
  );
}

Future<void> _tapEnsuringVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

void main() {
  testWidgets('pending deletion card shows scheduled date and cancel action',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final scheduled = DateTime.utc(2026, 8, 14);
    final service = _FakeAccountDeletionService(scheduledAt: scheduled);
    await tester.pumpWidget(_app(service, _NoopDataWipeService()));
    await tester.pumpAndSettle();

    expect(find.textContaining('2026-08-14'), findsOneWidget);
    expect(find.text('إلغاء الحذف'), findsWidgets);
  });

  testWidgets(
      'cancelling a pending deletion calls the service and hides the card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final scheduled = DateTime.utc(2026, 8, 14);
    final service = _FakeAccountDeletionService(scheduledAt: scheduled);
    await tester.pumpWidget(_app(service, _NoopDataWipeService()));
    await tester.pumpAndSettle();

    await _tapEnsuringVisible(tester, find.text('إلغاء الحذف').first);
    await tester.pumpAndSettle();
    // Confirmation dialog.
    await tester.tap(find.text('إلغاء الحذف').last);
    await tester.pumpAndSettle();

    expect(service.cancelCalls, 1);
    expect(find.textContaining('2026-08-14'), findsNothing);
  });

  testWidgets('no pending-deletion card when nothing is scheduled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final service = _FakeAccountDeletionService();
    await tester.pumpWidget(_app(service, _NoopDataWipeService()));
    await tester.pumpAndSettle();

    expect(find.textContaining('حسابك مجدول للحذف'), findsNothing);
  });

  testWidgets('confirming account deletion calls requestDeletion exactly once',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final service = _FakeAccountDeletionService();
    final wipe = _NoopDataWipeService();
    await tester.pumpWidget(_app(service, wipe));
    await tester.pumpAndSettle();

    await _tapEnsuringVisible(tester, find.text('حذف الحساب وكل بياناتي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف الحساب'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(service.requestCalls, 1);
    expect(wipe.wipeCalls, 1);
  });

  testWidgets(
      'a failed deletion request shows an error and does not wipe local data',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    final service = _FakeAccountDeletionService(throwOnRequest: true);
    final wipe = _NoopDataWipeService();
    await tester.pumpWidget(_app(service, wipe));
    await tester.pumpAndSettle();

    await _tapEnsuringVisible(tester, find.text('حذف الحساب وكل بياناتي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف الحساب'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(service.requestCalls, 1);
    expect(wipe.wipeCalls, 0);
    expect(find.text('تعذّر جدولة الحذف الآن. حاول مجدداً.'), findsOneWidget);

    // AppToast schedules a static 3-second auto-dismiss Timer (app_toast.dart)
    // that outlives this test's widget tree unless drained here.
    await tester.pump(const Duration(seconds: 3));
  });
}
