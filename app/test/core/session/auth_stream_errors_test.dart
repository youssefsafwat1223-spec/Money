// SDK error injection exercises its real broadcast stream; no production use.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';
import 'package:money_companion/core/session/auth_stream_boundary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/session/app_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual GoTrue error broadcast is contained by app subscription',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final client = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    final errors = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() async {
      await AppSession.instance.bindSupabaseAuth(client);
      client.auth.notifyException(const AuthException('synthetic denied'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      done.complete();
    }, (error, stack) => errors.add(error));
    await done.future.timeout(const Duration(seconds: 2));
    expect(errors, isEmpty);
    final session = AppSession.instance;
    session.configureCaptureOwnerClear(() async => true);
    await session.completeOnboarding(method: 'google', userId: 'fresh-b');
    final before = await const FlutterSecureStorage().readAll();
    final status = session.status;
    client.auth.notifyException(const AuthException('late old-user failure'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(session.status, status);
    expect(await const FlutterSecureStorage().readAll(), before);
    await session.wipeAndReset();
    final removed = await const FlutterSecureStorage().readAll();
    client.auth
        .notifyException(const AuthException('late removed-user failure'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await const FlutterSecureStorage().readAll(), removed);
    expect(await session.readLocalDataOwnerUid(), isNull);
    await client.dispose();
  });
  for (final source in ['appSession', 'senderBankMapping']) {
    test('$source expected errors are observed and listener remains alive',
        () async {
      final reports = <String>[];
      final events = <int>[];
      final boundary = AuthStreamBoundary(source,
          reporter: (source, origin, type, expected) =>
              reports.add('$origin:$type:$expected'));
      final stream = StreamController<int>.broadcast();
      final subscription =
          stream.stream.listen(events.add, onError: boundary.onError);
      stream.addError(const AuthException('secret must not be reported'));
      stream.add(1);
      await Future<void>.delayed(Duration.zero);
      expect(reports, ['stream:AuthException:true']);
      expect(events, [1]);
      await subscription.cancel();
      await stream.close();
    });
  }
  test('callback expected failure is reported without escaping', () async {
    final reports = <String>[];
    final boundary = AuthStreamBoundary('appSession',
        reporter: (source, origin, type, expected) =>
            reports.add('$origin:$expected'));
    await boundary.run(() async => throw const AuthException('secret'));
    expect(reports, ['callback:true']);
  });
  test('unexpected callback failure remains observable as unexpected',
      () async {
    final reports = <String>[];
    final boundary = AuthStreamBoundary('senderBankMapping',
        reporter: (source, origin, type, expected) =>
            reports.add('$type:$expected'));
    await boundary.run(() => throw StateError('secret'));
    expect(reports, ['StateError:false']);
  });
  test('cancelled listener does not receive errors after remount', () async {
    final reports = <String>[];
    final boundary = AuthStreamBoundary('senderBankMapping',
        reporter: (source, origin, type, expected) => reports.add(type));
    final stream = StreamController<int>.broadcast();
    final old = stream.stream.listen((_) {}, onError: boundary.onError);
    await old.cancel();
    final replacement = stream.stream.listen((_) {}, onError: boundary.onError);
    stream.addError(const AuthException('secret'));
    await Future<void>.delayed(Duration.zero);
    expect(reports, ['AuthException']);
    await replacement.cancel();
    await stream.close();
  });
  test('explicit failed authentication Future still surfaces its error',
      () async {
    final client = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        httpClient: MockClient((_) async =>
            http.Response('{"msg":"synthetic invalid credentials"}', 400)),
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    await expectLater(
        client.auth
            .signInWithPassword(email: 'a@example.test', password: 'synthetic'),
        throwsA(isA<AuthException>()));
    await client.dispose();
  });
  test('unexpected stream failure reports only its type', () {
    final reports = <String>[];
    final boundary = AuthStreamBoundary('appSession',
        reporter: (source, origin, type, expected) => reports.add('$origin:$type:$expected'));
    boundary.onError(StateError('credential-shaped secret'), StackTrace.current);
    expect(reports, ['stream:StateError:false']);
  });
  test('both production subscriptions wire stream and callback boundaries', () {
    final appSession = File('lib/core/session/app_session.dart').readAsStringSync();
    final startup = File('lib/core/startup/bootstrap_runner.dart').readAsStringSync();
    expect(appSession, contains('onError: boundary.onError'));
    expect(appSession, contains('boundary.run(() => _handleSupabaseAuthChange(state, client))'));
    expect(startup, contains('onError: boundary.onError'));
    final receiverStart = startup.indexOf('  void _receiveSenderBankMapping(');
    final receiverEnd = startup.indexOf('  Future<void> waitPendingSenderBankMappingSync()', receiverStart);
    expect(receiverStart, greaterThanOrEqualTo(0));
    expect(receiverEnd, greaterThan(receiverStart));
    final receiver = startup.substring(receiverStart, receiverEnd);
    expect(RegExp(r'_senderJobs\.add\(completion\.future\);[\s\S]*?'
        r'unawaited\(Future<void>\.microtask').hasMatch(receiver), isTrue,
        reason: 'the owned completion must be registered before starting the deferred receiver');
    expect(receiver, contains('await service.syncWithPhase(SyncPhaseBinding(), originalAuthority: original);'));
    expect(RegExp(r'on AccountFenceDeliveryCancellation\s*\{[\s\S]*?'
        r'on StaleAdmissionException\s*\{[\s\S]*?'
        r'catch \(error, stack\)\s*\{\s*'
        r'_senderUnexpected\.add\(\(error, stack\)\);\s*'
        r"const AuthStreamBoundary\('senderBankMapping'\)\.onError\(error, stack\);\s*"
        r'\} finally \{\s*'
        r'_senderReceiving\.remove\(key\);\s*'
        r'_senderJobs\.remove\(completion\.future\);\s*'
        r'completion\.complete\(\);').hasMatch(receiver), isTrue,
        reason: 'expected cancellation stays separate; ordinary errors remain reported and owned work always settles');
  });

}
