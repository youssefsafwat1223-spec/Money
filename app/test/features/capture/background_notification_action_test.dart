import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';
import 'package:money_companion/features/capture/services/pending_notification_actions.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// إجراءات الإشعار (تأكيد/تجاهل) والتطبيق مغلق: يجب أن تُسجَّل دائمًا في
/// الملف الاحتياطي كي يعيد التطبيق تطبيقها عبر الـ routed repository عند أول
/// فتح — في وضع transactions_supabase_primary التعديل المحلي وحده يعني ضياع
/// الإجراء على الخادم (الـ isolate الخلفي لا يعرف قيمة العلامة الفعلية).
class _FakePathProvider extends PlatformInterface
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.root) : super(token: _token);

  static final Object _token = Object();
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;

  @override
  Future<List<String>?> getExternalCachePaths() async => [root];

  @override
  Future<String?> getExternalStoragePath() async => root;

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async =>
      [root];

  @override
  Future<String?> getLibraryPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bg_actions_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('background confirm while app is closed is recorded for replay',
      () async {
    await LocalNotificationService.debugRunBackgroundAction(
      'tx-confirm-1',
      confirm: true,
    );

    final drained = await PendingNotificationActions.drain();
    expect(drained, hasLength(1));
    expect(drained.single.transactionId, 'tx-confirm-1');
    expect(drained.single.confirm, isTrue);

    // السحب يمسح الملف — لا إعادة تطبيق مكررة في الفتحات اللاحقة.
    expect(await PendingNotificationActions.drain(), isEmpty);
  });

  test(
      'MALI-070n: clear() deletes queued actions so they never replay under the '
      'next identity, and is safe when the file is absent', () async {
    await LocalNotificationService.debugRunBackgroundAction(
      'tx-user-a',
      confirm: true,
    );

    // Destructive sign-out purges the file outright (no draining/applying).
    expect(await PendingNotificationActions.clear(), isTrue);

    // The next user drains nothing — user A's action cannot execute under B.
    expect(await PendingNotificationActions.drain(), isEmpty);
    // Idempotent: clearing an already-absent file still reports success.
    expect(await PendingNotificationActions.clear(), isTrue);
  });

  test('background dismiss while app is closed is recorded for replay',
      () async {
    await LocalNotificationService.debugRunBackgroundAction(
      'tx-dismiss-1',
      confirm: false,
    );

    final drained = await PendingNotificationActions.drain();
    expect(drained, hasLength(1));
    expect(drained.single.transactionId, 'tx-dismiss-1');
    expect(drained.single.confirm, isFalse);
  });

  test('latest action for the same transaction wins', () async {
    await LocalNotificationService.debugRunBackgroundAction(
      'tx-flip',
      confirm: true,
    );
    await LocalNotificationService.debugRunBackgroundAction(
      'tx-flip',
      confirm: false,
    );

    final drained = await PendingNotificationActions.drain();
    expect(drained, hasLength(1));
    expect(drained.single.confirm, isFalse);
  });

  test(
      'sequential drains (app startup, then a later resume) never return '
      'the same action twice', () async {
    await LocalNotificationService.debugRunBackgroundAction(
      'tx-race-1',
      confirm: true,
    );

    // Simulates AppShell's initial-mount drain followed by a later
    // AppLifecycleState.resumed drain for the same pending action. AppShell
    // never issues these two calls concurrently — _reconcileDataAfterResume
    // guards re-entry with _isReconcilingAfterResume, so a resume firing
    // while startup reconciliation is still running is a no-op rather than
    // a second overlapping drain(). Note: PendingNotificationActions.drain()
    // itself is a read-then-delete and is NOT safe against true concurrent
    // callers — the AppShell guard is what keeps calls to it sequential.
    final first = await PendingNotificationActions.drain();
    final second = await PendingNotificationActions.drain();

    final totalDrained = [...first, ...second];
    expect(totalDrained, hasLength(1));
    expect(totalDrained.single.transactionId, 'tx-race-1');
  });
}
