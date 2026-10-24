import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/account_deletion_service.dart';
import 'package:money_companion/core/auth/immediate_account_deletion.dart';
import 'package:money_companion/core/auth/immediate_deletion_receipt_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException, SupabaseClient, AuthClientOptions, GotrueAsyncStorage;
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import '../../harness/egress_test_support.dart';

const _secret = 'A0123456789012345678901234567890123456789ab';
final _url = Uri.parse('https://example.supabase.co/functions/v1/delete-account-immediate');

ImmediateAccountDeletionClient _client(
  Future<http.Response> Function(http.Request) handler, {
  Future<String?> Function()? token,
  Duration timeout = const Duration(seconds: 5),
  List<http.Request>? sink,
}) {
  return ImmediateAccountDeletionClient(
    httpClient: MockClient((req) async {
      sink?.add(req);
      return handler(req);
    }),
    functionUrl: _url,
    accessToken: token ?? () async => 'jwt-abc',
    requestTimeout: timeout,
  );
}

Future<ImmediateAccountDeletionRecovery> _safeRecovery(
    Future<http.Response> Function(http.Request) handler, {List<http.Request>? sink, String? pendingSecret}) async {
  final values = <String, String>{};
  final store = ImmediateDeletionReceiptStore(authority: Object(),
      read: (key) async => values[key], write: (key, value) async { values[key] = value; });
  if (pendingSecret != null) {
    await store.writeVerified(ImmediateDeletionReceipt(owner: 'uid-a', operationId: 'pending-operation',
        receiptSecret: pendingSecret, phase: ImmediateDeletionPhase.mayHaveBeenSent));
  }
  return ImmediateAccountDeletionRecovery(
    store: store,
    transport: MockClient((req) async { sink?.add(req); return handler(req); }),
    functionUrl: _url,
    captureBinding: () async => const ImmediateDeletionBinding(owner: 'uid-a', lifecycle: 1, bearerToken: 'jwt-abc'),
    isBindingCurrent: (_) => true,
  );
}

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Future<ImmediateDeletionResult> _request(ImmediateAccountDeletionClient c) =>
    c.request(
      challengeId: 'challenge-0001',
      challengeResponse: 'apple-proof',
      receiptSecret: _secret,
    );

void main() {
  _configuredLegacyDeletionStageA();
  group('E6 part2 fail-before-fix contracts', () {
    test('receipt status never calls a throwing token provider', () async {
      var tokenCalls = 0;
      final sink = <http.Request>[];
      final c = _client((_) async => _json(200, {'status': 'completed'}),
          token: () async { tokenCalls++; throw StateError('must not refresh'); },
          sink: sink);
      expect(await c.status(receiptSecret: _secret), isA<ImmediateDeletionCompleted>());
      expect(tokenCalls, 0);
      expect(sink.single.headers.containsKey('Authorization'), isFalse);
    });

    test('receipt status has no user Authorization even when signed in', () async {
      final sink = <http.Request>[];
      await _client((_) async => _json(200, {'status': 'in_progress'}), sink: sink)
          .status(receiptSecret: _secret);
      expect(sink.single.headers.containsKey('Authorization'), isFalse);
    });

    test('raw HTTP alone cannot configure the service safe path', () async {
      final sink = <http.Request>[];
      final service = AccountDeletionService(immediateClient:
          _client((_) async => _json(200, {'status': 'completed'}), sink: sink));
      final result = await service.requestImmediateDeletion(
          challengeId: 'challenge-0001', challengeResponse: 'proof');
      expect(result, isA<ImmediateDeletionFailed>());
      expect((result as ImmediateDeletionFailed).code, 'not_configured');
      expect(sink, isEmpty);
    });
  });

  group('typed states from server confirmation only', () {
    test('200 completed is the only way to completed', () async {
      final r = await _request(
          _client((_) async => _json(200, {'status': 'completed'})));
      expect(r, isA<ImmediateDeletionCompleted>());
      expect(r.receiptSecret, _secret);
    });

    test('202 in_progress is inProgress and never completed', () async {
      final r = await _request(
          _client((_) async => _json(202, {'status': 'in_progress'})));
      expect(r, isA<ImmediateDeletionInProgress>());
    });

    test('200 accepted is accepted', () async {
      final r = await _request(
          _client((_) async => _json(200, {'status': 'accepted'})));
      expect(r, isA<ImmediateDeletionAccepted>());
    });

    test('completed on a non-200 response is rejected as invalid', () async {
      final r = await _request(
          _client((_) async => _json(202, {'status': 'completed'})));
      expect(r, isA<ImmediateDeletionFailed>());
      expect((r as ImmediateDeletionFailed).retryable, isTrue);
      expect(r.code, 'invalid_response');
    });

    test('an unknown status string is never success', () async {
      final r = await _request(
          _client((_) async => _json(200, {'status': 'deleted'})));
      expect(r, isA<ImmediateDeletionFailed>());
    });

    test('an empty, non-JSON or array body on 200 is never success', () async {
      for (final body in ['', 'ok', '[]', 'null', '{"x":1}']) {
        final r = await _request(
            _client((_) async => http.Response(body, 200)));
        expect(r, isA<ImmediateDeletionFailed>(), reason: body);
        expect((r as ImmediateDeletionFailed).retryable, isTrue);
      }
    });
  });

  group('errors are failures, never success', () {
    test('retryable server error keeps the flag and code', () async {
      final r = await _request(_client((_) async => _json(503,
          {'status': 'error', 'code': 'store_unavailable', 'retryable': true})));
      final f = r as ImmediateDeletionFailed;
      expect(f.retryable, isTrue);
      expect(f.code, 'store_unavailable');
      expect(f.lookupReceipt, isFalse);
    });

    test('acceptance_unknown asks the caller to look the receipt up with the SAME secret',
        () async {
      final r = await _request(_client((_) async => _json(503, {
            'status': 'error',
            'code': 'acceptance_unknown',
            'retryable': true,
            'recovery': 'lookup_receipt'
          })));
      final f = r as ImmediateDeletionFailed;
      expect(f.retryable, isTrue);
      expect(f.lookupReceipt, isTrue);
      expect(f.receiptSecret, _secret);
    });

    test('non-retryable verdicts are not retryable', () async {
      for (final code in [
        'unauthenticated',
        'challenge_expired',
        'apple_subject_mismatch',
        'idempotency_conflict',
        'not_configured',
      ]) {
        final r = await _request(_client((_) async => _json(
            400, {'status': 'error', 'code': code, 'retryable': false})));
        final f = r as ImmediateDeletionFailed;
        expect(f.retryable, isFalse, reason: code);
        expect(f.code, code);
      }
    });

    test('a bare 401 is non-retryable unauthenticated; a bare 5xx is retryable', () async {
      final a = await _request(_client((_) async => http.Response('', 401)))
          as ImmediateDeletionFailed;
      expect([a.retryable, a.code], [false, 'unauthenticated']);
      final b = await _request(_client((_) async => http.Response('boom', 502)))
          as ImmediateDeletionFailed;
      expect([b.retryable, b.code], [true, 'server_error']);
    });

    test('a transport error is a retryable failure, not success and not nonacceptance',
        () async {
      final r = await _request(
          _client((_) async => throw http.ClientException('socket')));
      final f = r as ImmediateDeletionFailed;
      expect(f.retryable, isTrue);
      expect(f.code, 'network');
      expect(f.receiptSecret, _secret);
    });

    test('a timeout is a retryable failure whose outcome is unknown', () async {
      final r = await _request(_client((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _json(200, {'status': 'completed'});
      }, timeout: const Duration(milliseconds: 20)));
      final f = r as ImmediateDeletionFailed;
      expect(f.retryable, isTrue);
      expect(f.code, 'timeout');
      expect(f.lookupReceipt, isTrue);
    });

    test('no session means no request at all', () async {
      final sink = <http.Request>[];
      final r = await _request(_client((_) async => _json(200, {}),
          token: () async => null, sink: sink));
      expect((r as ImmediateDeletionFailed).code, 'unauthenticated');
      expect(r.retryable, isFalse);
      expect(sink, isEmpty);
    });

    test('server text is never copied into the failure', () async {
      final r = await _request(_client((_) async => _json(500, {
            'status': 'error',
            'code': 'sql_purge_error: relation x leaked',
            'retryable': true,
            'message': 'secret-detail'
          })));
      final f = r as ImmediateDeletionFailed;
      expect(f.toString(), isNot(contains('secret-detail')));
      expect(f.code, 'server_error');
    });
  });

  group('request shape', () {
    test('POSTs only the three fields plus bearer; never a uid or email', () async {
      final sink = <http.Request>[];
      await _request(_client((_) async => _json(200, {'status': 'completed'}),
          sink: sink));
      final req = sink.single;
      expect(req.method, 'POST');
      expect(req.url, _url);
      expect(req.headers['Authorization'], 'Bearer jwt-abc');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body.keys.toSet(),
          {'challenge_id', 'challenge_response', 'receipt_secret'});
      expect(body['receipt_secret'], _secret);
    });

    test('status poll sends action=status and the receipt only', () async {
      final sink = <http.Request>[];
      final c = _client((_) async => _json(200, {'status': 'in_progress'}),
          sink: sink);
      final r = await c.status(receiptSecret: _secret);
      expect(r, isA<ImmediateDeletionInProgress>());
      final body = jsonDecode(sink.single.body) as Map<String, dynamic>;
      expect(body, {'action': 'status', 'receipt_secret': _secret});
    });

    test('status unknown (404) is a non-retryable failure, never success', () async {
      final c = _client((_) async => _json(404, {'status': 'unknown'}));
      final f = await c.status(receiptSecret: _secret) as ImmediateDeletionFailed;
      expect([f.retryable, f.code], [false, 'unknown']);
    });

    test('status unavailable (503) is retryable', () async {
      final c = _client((_) async => _json(503, {'status': 'unavailable'}));
      final f = await c.status(receiptSecret: _secret) as ImmediateDeletionFailed;
      expect([f.retryable, f.code], [true, 'unavailable']);
    });

    test('a malformed receipt secret is rejected locally without a request', () async {
      final sink = <http.Request>[];
      final c = _client((_) async => _json(200, {}), sink: sink);
      final f = await c.request(
        challengeId: 'challenge-0001',
        challengeResponse: 'p',
        receiptSecret: 'short',
      ) as ImmediateDeletionFailed;
      expect([f.retryable, f.code], [false, 'invalid_request']);
      expect(sink, isEmpty);
    });
  });

  group('receipt secret', () {
    test('is 43 url-safe characters from 32 random bytes', () {
      final s = generateReceiptSecret();
      expect(s.length, 43);
      expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(s), isTrue);
      expect(generateReceiptSecret(), isNot(s));
    });

    test('uses the injected random source', () {
      final a = generateReceiptSecret(random: Random(1));
      final b = generateReceiptSecret(random: Random(1));
      expect(a, b);
    });
  });

  group('account-fence database error classification', () {
    PostgrestException pg(String code) =>
        PostgrestException(message: 'x', code: code);

    test('55P03 is transient contention that must not consume an attempt', () {
      final k = classifyAccountFenceError(pg('55P03'));
      expect(k, AccountFenceErrorKind.contention);
      expect(k.consumesAttempt, isFalse);
      expect(k.isSuccess, isFalse);
    });

    test('QD001 is pending deletion: stop writing, never success, no attempt consumed', () {
      final k = classifyAccountFenceError(pg('QD001'));
      expect(k, AccountFenceErrorKind.deletionPending);
      expect(k.consumesAttempt, isFalse);
      expect(k.isSuccess, isFalse);
    });

    test('QD002 means the account is gone', () {
      expect(classifyAccountFenceError(pg('QD002')), AccountFenceErrorKind.accountGone);
    });

    test('unrelated codes, 409 and 42501 are not fence errors', () {
      for (final c in ['409', '42501', '23505', '500', 'PGRST301']) {
        expect(classifyAccountFenceError(pg(c)), AccountFenceErrorKind.none, reason: c);
      }
      expect(classifyAccountFenceError(StateError('x')), AccountFenceErrorKind.none);
    });
  });

  group('AccountDeletionService integration', () {
    test('requestImmediateDeletion with no configured client is a non-retryable failure', () async {
      final service = AccountDeletionService();
      final r = await service.requestImmediateDeletion(
          challengeId: 'challenge-0001', challengeResponse: 'p');
      expect(r, isA<ImmediateDeletionFailed>());
      expect((r as ImmediateDeletionFailed).code, 'not_configured');
      expect(r.retryable, isFalse);
    });

    test('generates a receipt secret when none is given and returns it', () async {
      final service = AccountDeletionService(
        immediateRecovery: await _safeRecovery((_) async => _json(202, {'status': 'in_progress'})),
      );
      final r = await service.requestImmediateDeletion(
          challengeId: 'challenge-0001', challengeResponse: 'p');
      expect(r, isA<ImmediateDeletionInProgress>());
      expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(r.receiptSecret), isTrue);
    });

    test('reuses a supplied receipt secret on retry', () async {
      final sink = <http.Request>[];
      final service = AccountDeletionService(
        immediateRecovery: await _safeRecovery((_) async => _json(200, {'status': 'completed'}), sink: sink, pendingSecret: _secret),
      );
      final r = await service.requestImmediateDeletion(
          challengeId: 'challenge-0001',
          challengeResponse: 'p',
          receiptSecret: _secret);
      expect(r.receiptSecret, _secret);
      expect((jsonDecode(sink.single.body) as Map)['receipt_secret'], _secret);
    });

    test('the legacy scheduled API is still callable (unused by new code)', () {
      final service = AccountDeletionService();
      // Compile-time proof of the retained legacy surface.
      final Future<DateTime?> Function() legacyRequest = service.requestDeletion;
      final Future<void> Function() legacyCancel = service.cancelDeletion;
      expect(legacyRequest, isNotNull);
      expect(legacyCancel, isNotNull);
    });
  });
}


// This group is an actual SDK/service boundary test only under the explicitly
// approved synthetic local configuration. Normal test runs report skipped.
void _configuredLegacyDeletionStageA() {
  const configured = String.fromEnvironment('SUPABASE_ENV') == 'local' &&
      String.fromEnvironment('SUPABASE_URL') == 'https://example.supabase.co' &&
      String.fromEnvironment('SUPABASE_ANON_KEY') == 'anon';
  group('QD003 configured legacy RPC StageA', () {
    late CloudEgressGate previous;
    late SupabaseClient client;
    late AccountDeletionService service;
    late Future<http.Response> Function(http.Request) response;
    late List<http.Request> requests;
    late List<Object?> returnedBodies;
    setUp(() {
      previous=CloudEgressGate.instance;
      TestEgress().install();
      requests=[];returnedBodies=[];
      client=SupabaseClient('https://example.supabase.co','anon',
          authOptions:AuthClientOptions(autoRefreshToken:false,
              pkceAsyncStorage:_LegacySdkStorage()),
          httpClient:GatedHttpClient(MockClient((request)async{
            requests.add(request);
            final reply=await response(request);
            returnedBodies.add(jsonDecode(reply.body));
            return reply;
          })));
      service=AccountDeletionService(getClient:()=>client);
      expect(SupabaseConfig.isConfigured,isTrue);
    });
    tearDown(()async{
      try{await client.dispose();}finally{CloudEgressGate.instance=previous;}
    });
    void observedRequest(Object body) {
      expect(requests,hasLength(1));
      final request=requests.single;
      expect(request.method,'POST');
      expect(request.url,Uri.parse('https://example.supabase.co/rest/v1/rpc/request_account_deletion'));
      expect(jsonDecode(request.body),isNull,reason:'the SDK sends null for this parameterless RPC');
      expect(returnedBodies,[body]);
    }
    test('exact raw legacy unavailable is not flattened into generic server failure',()async{
      final body=<String,Object?>{'code':'QD003','message':'legacy_scheduled_deletion_disabled','details':null,'hint':null};
      response=(request)async=>http.Response(jsonEncode(body),400,
          headers:{'content-type':'application/json'},request:request);
      Object? failure;DateTime? result;
      try{result=await service.requestDeletion();}catch(error){failure=error;}
      observedRequest(body);
      expect(failure,isNotNull,reason:'the observed unavailable RPC response cannot be a date/null success');
      expect(result,isNull);
      expect(failure,isNot(isA<ServerRepoException>()),
          reason:'exact QD003 must survive this legacy request boundary as unavailable');
      expect(failure,isA<LegacyDeletionUnavailable>().having((e)=>e.code,
          'stable unavailable code','legacy_route_unavailable'));
      expect(failure.toString(),isNot(contains(body['message'] as String)));
    });
    test('successful legacy schedule preserves its exact UTC date',()async{
      const body='2026-11-20T12:00:00Z';
      response=(request)async=>http.Response(jsonEncode(body),200,
          headers:{'content-type':'application/json'},request:request);
      final result=await service.requestDeletion();
      observedRequest(body);expect(result,DateTime.utc(2026,11,20,12));expect(result!.isUtc,isTrue);
    });
    test('ordinary backend failure keeps the existing mapped error',()async{
      final body=<String,Object?>{'code':'XX000','message':'QD003 legacy_scheduled_deletion_disabled text is not a typed code','details':null,'hint':null};
      response=(request)async=>http.Response(jsonEncode(body),500,
          headers:{'content-type':'application/json'},request:request);
      Object? failure;
      try{await service.requestDeletion();}catch(error){failure=error;}
      observedRequest(body);expect(failure,isA<ServerRepoException>());
    });
  },skip:configured?false:'Requires only the approved synthetic local SUPABASE_ENV/URL/ANON_KEY defines; default run does not exercise configured legacy RPC coverage.');

  group('challenge()', () {
    Map<String, Object?> issued() => {
          'status': 'challenge',
          'challenge_id': 'challenge-id-0123456789abcdef',
          'nonce': 'raw-nonce-0123456789abcdef',
          'expires_at_ms': 4102444800000,
        };

    test('sends exactly {action:challenge} with the Bearer token and maps the issue', () async {
      final sink = <http.Request>[];
      final result = await _client((_) async => _json(200, issued()), sink: sink).challenge();
      expect(result, isA<ImmediateChallengeIssued>());
      final issuedResult = result as ImmediateChallengeIssued;
      expect(issuedResult.challengeId, 'challenge-id-0123456789abcdef');
      expect(issuedResult.nonce, 'raw-nonce-0123456789abcdef');
      expect(issuedResult.expiresAtMs, 4102444800000);
      expect(sink.single.method, 'POST');
      expect(sink.single.headers['Authorization'], 'Bearer jwt-abc');
      expect(jsonDecode(sink.single.body), {'action': 'challenge'});
      expect('$result', isNot(contains('raw-nonce')));
    });

    Future<ImmediateChallengeResult> reply(int status, Object body) =>
        _client((_) async => _json(status, body)).challenge();

    test('admin_self_delete_blocked, challenge_rate_limited and already_pending are typed refusals', () async {
      final admin = await reply(403, {'status': 'error', 'code': 'admin_self_delete_blocked'});
      expect((admin as ImmediateChallengeRefused).reason, ImmediateChallengeRefusal.adminBlocked);
      final limited = await reply(429, {'status': 'error', 'code': 'challenge_rate_limited'});
      expect((limited as ImmediateChallengeRefused).reason, ImmediateChallengeRefusal.rateLimited);
      final bare429 = await reply(429, {'status': 'error'});
      expect((bare429 as ImmediateChallengeRefused).reason, ImmediateChallengeRefusal.rateLimited);
      for (final r in [
        await reply(409, {'status': 'error', 'code': 'already_pending'}),
        await reply(200, {'status': 'accepted', 'code': 'already_pending'}),
        await reply(202, {'status': 'accepted'}),
        await reply(200, {'status': 'in_progress'}),
      ]) {
        expect((r as ImmediateChallengeRefused).reason, ImmediateChallengeRefusal.alreadyPending);
      }
    });

    test('malformed, incomplete or unexpected replies are failures, never an issued challenge', () async {
      for (final body in <Object>[
        {'status': 'challenge'},
        {...issued(), 'nonce': ''},
        {...issued(), 'challenge_id': 7},
        {...issued(), 'expires_at_ms': 'soon'},
        {'status': 'completed'},
        'not json',
      ]) {
        final r = await _client((_) async => http.Response(
            body is String ? body : jsonEncode(body), 200)).challenge();
        expect(r, isA<ImmediateChallengeFailed>(), reason: '$body');
      }
      final server = await reply(503, {'status': 'unavailable'});
      expect((server as ImmediateChallengeFailed).retryable, isTrue);
      final unauth = await reply(401, {'status': 'error'});
      expect((unauth as ImmediateChallengeFailed).retryable, isFalse);
    });

    test('transport errors, timeouts and a missing token fail without sending', () async {
      final net = await _client((_) async => throw http.ClientException('down')).challenge();
      expect((net as ImmediateChallengeFailed).code, 'network');
      final sink = <http.Request>[];
      final none = await _client((_) async => _json(200, issued()), token: () async => null, sink: sink).challenge();
      expect((none as ImmediateChallengeFailed).code, 'unauthenticated');
      expect(sink, isEmpty);
    });
  });
}

class _LegacySdkStorage extends GotrueAsyncStorage {
  final values=<String,String>{};
  @override
  Future<String?> getItem({required String key})async=>values[key];
  @override
  Future<void> setItem({required String key,required String value})async{values[key]=value;}
  @override
  Future<void> removeItem({required String key})async{values.remove(key);}
}
