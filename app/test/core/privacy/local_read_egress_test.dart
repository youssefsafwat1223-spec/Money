import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';

import '../../harness/egress_test_support.dart';

// Astra D6 — while a verified local-read scope is published the ONE admission
// gate admits nothing but an operation-scoped account-control grant (explicit
// sign-in / reconnect). A saved Cloud ON record changes nothing: the SDK's own
// refresh ticks, resume ticks, services, images and diagnostics all go through
// this gate, and every one of them is refused. Reaching the inner client at all
// would be a network attempt.

const _url = 'https://example.supabase.co';

void main() {
  late TestEgress egress;
  late CloudEgressGate gate;
  var localRead = false;
  late List<http.BaseRequest> reached;
  late GatedHttpClient transport;

  setUp(() {
    localRead = false;
    reached = [];
    egress = TestEgress(seedOn: true)..install();
    gate = egress.gate..localReadActive = () => localRead;
    transport = GatedHttpClient(MockClient((request) async {
      reached.add(request);
      return http.Response('{}', 200);
    }));
  });
  tearDown(() => CloudEgressGate.instance = CloudEgressGate());

  Future<Object?> send(String method, String url) async {
    try {
      await transport.send(http.Request(method, Uri.parse(url)));
      return null;
    } catch (e) {
      return e;
    }
  }

  test('control: with Cloud ON and no local read the same request is admitted',
      () async {
    expect(await gate.permits(), isTrue);
    expect(await send('POST', '$_url/rest/v1/rpc/x'), isNull);
    expect(reached, hasLength(1));
  });

  test('local read: a saved Cloud ON record admits no automatic request',
      () async {
    localRead = true;
    expect(await gate.permits(), isFalse);
    expect(gate.permitsNetworkSync, isFalse);
    for (final (method, path) in [
      ('POST', '/auth/v1/token?grant_type=refresh_token'), // SDK refresh tick
      ('GET', '/rest/v1/profiles'),
      ('POST', '/rest/v1/rpc/log_event'),
      ('POST', '/functions/v1/anything'),
      ('GET', '/storage/v1/object/x'),
    ]) {
      final e = await send(method, '$_url$path');
      expect(e, isA<EgressDeniedException>(), reason: '$method $path');
    }
    expect(reached, isEmpty, reason: 'nothing reached the network');
  });

  test('local read: an explicit account-control sign-in is still admitted',
      () async {
    localRead = true;
    final r = await gate.runAccountControl(AccountControlOp.signIn, () async {
      final response = await transport.send(http.Request('POST',
          Uri.parse('$_url/auth/v1/token?grant_type=id_token')));
      return response.statusCode;
    });
    expect(r, 200);
    expect(reached, hasLength(1));
  });

  test('local read: an account-control grant never widens beyond its '
      'allowlist', () async {
    localRead = true;
    final e = await gate.runAccountControl(AccountControlOp.signIn, () async {
      try {
        await transport.send(
            http.Request('GET', Uri.parse('$_url/rest/v1/profiles')));
        return null;
      } catch (e) {
        return e;
      }
    });
    expect(e, isA<EgressDeniedException>());
    expect(reached, isEmpty);
  });

  test('local read: an explicit owner argument does not bypass the guard',
      () async {
    localRead = true;
    await expectLater(
        gate.admit(
            owner: 'uid-a',
            request: AdmissionRequest('GET', Uri.parse('$_url/rest/v1/x'))),
        throwsA(isA<EgressDeniedException>()));
  });

  test('leaving local read restores the saved Cloud ON behaviour', () async {
    localRead = true;
    expect(await send('GET', '$_url/rest/v1/x'), isA<EgressDeniedException>());
    localRead = false;
    expect(await gate.permits(), isTrue);
    expect(await send('GET', '$_url/rest/v1/x'), isNull);
    expect(reached, hasLength(1));
  });
}
