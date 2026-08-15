// MALI-COUPONS (Phase C4) — analytics client contract (§43 A, G–L).
// Consent gating, session dedup, payload privacy, and the guarantee that a
// failing send can never surface an error or block the user's action.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/coupons/coupon_analytics.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

UserSettingsEntity _settings({required ConsentState cloud}) => UserSettingsEntity(
      id: 'user_settings',
      theme: 'dark',
      currency: 'SAR',
      language: 'ar',
      country: 'SA',
      inputMethod: 'sms',
      notificationsJson: '{}',
      privacyModeEnabled: false,
      cloudConsentState: cloud,
    );

/// Captures every RPC body the client sends.
class _Recorder {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
  final List<String> paths = <String>[];

  SupabaseClient client({bool fail = false}) => SupabaseClient(
        'https://example.supabase.co',
        'anon',
        accessToken: () async => 'jwt',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.body.isNotEmpty) {
            calls.add((jsonDecode(request.body) as Map).cast<String, Object?>());
          }
          if (fail) {
            return http.Response('{"message":"boom"}', 500, request: request);
          }
          return http.Response('{}', 200,
              headers: const {'content-type': 'application/json'}, request: request);
        }),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('A: consent OFF (declined or unset) sends NOTHING', () async {
    for (final state in [ConsentState.declined, ConsentState.unset]) {
      final recorder = _Recorder();
      final analytics = CouponAnalyticsClient(
        client: recorder.client(),
        hasSession: (_) => true,
        loadSettings: () async => _settings(cloud: state),
      );
      await analytics.recordImpression('c1');
      await analytics.recordDetailView('c1');
      await analytics.recordCodeCopy('c1');
      await analytics.recordCtaClick('c1');
      expect(recorder.calls, isEmpty, reason: 'consent $state must send nothing');
    }
  });

  test('consent ON sends exactly the four approved event names', () async {
    final recorder = _Recorder();
    final analytics = CouponAnalyticsClient(
      client: recorder.client(),
      hasSession: (_) => true,
      loadSettings: () async => _settings(cloud: ConsentState.accepted),
    );
    await analytics.recordImpression('c1');
    await analytics.recordDetailView('c1');
    await analytics.recordCodeCopy('c1');
    await analytics.recordCtaClick('c1');

    expect(recorder.calls.map((c) => c['p_event']).toList(),
        ['impression', 'detail_view', 'code_copy', 'cta_click']);
    expect(recorder.paths.every((p) => p.endsWith('/rpc/record_coupon_event')), isTrue);
    // There is no `save` event in V1.
    expect(recorder.calls.any((c) => c['p_event'] == 'save'), isFalse);
  });

  test('B/C: impression is claimed once per coupon per session', () async {
    final recorder = _Recorder();
    final analytics = CouponAnalyticsClient(
      client: recorder.client(),
      hasSession: (_) => true,
      loadSettings: () async => _settings(cloud: ConsentState.accepted),
    );
    // Repeated calls model rebuilds and scroll re-entry.
    for (var i = 0; i < 5; i++) {
      await analytics.recordImpression('c1');
    }
    await analytics.recordImpression('c2');

    final impressions =
        recorder.calls.where((c) => c['p_event'] == 'impression').toList();
    expect(impressions, hasLength(2));
    expect(impressions.map((c) => c['p_coupon_id']).toSet(), {'c1', 'c2'});
  });

  test('G: detail_view is claimed once per coupon per session', () async {
    final recorder = _Recorder();
    final analytics = CouponAnalyticsClient(
      client: recorder.client(),
      hasSession: (_) => true,
      loadSettings: () async => _settings(cloud: ConsentState.accepted),
    );
    await analytics.recordDetailView('c1');
    await analytics.recordDetailView('c1');
    await analytics.recordDetailView('c1');
    expect(recorder.calls.where((c) => c['p_event'] == 'detail_view'), hasLength(1));
  });

  test('a NEW session (new client instance) may count again', () async {
    final recorder = _Recorder();
    CouponAnalyticsClient build() => CouponAnalyticsClient(
          client: recorder.client(),
          hasSession: (_) => true,
          loadSettings: () async => _settings(cloud: ConsentState.accepted),
        );
    await build().recordImpression('c1');
    await build().recordImpression('c1'); // fresh process/session
    expect(recorder.calls.where((c) => c['p_event'] == 'impression'), hasLength(2));
  });

  test('H/I: every explicit copy and CTA press counts (never debounced)', () async {
    final recorder = _Recorder();
    final analytics = CouponAnalyticsClient(
      client: recorder.client(),
      hasSession: (_) => true,
      loadSettings: () async => _settings(cloud: ConsentState.accepted),
    );
    await analytics.recordCodeCopy('c1');
    await analytics.recordCodeCopy('c1');
    await analytics.recordCtaClick('c1');
    await analytics.recordCtaClick('c1');
    expect(recorder.calls.where((c) => c['p_event'] == 'code_copy'), hasLength(2));
    expect(recorder.calls.where((c) => c['p_event'] == 'cta_click'), hasLength(2));
  });

  test('J: a failing send never throws (the user action always completes)', () async {
    final recorder = _Recorder();
    final analytics = CouponAnalyticsClient(
      client: recorder.client(fail: true),
      hasSession: (_) => true,
      loadSettings: () async => _settings(cloud: ConsentState.accepted),
    );
    await expectLater(analytics.recordCodeCopy('c1'), completes);
    await expectLater(analytics.recordCtaClick('c1'), completes);
    // A throwing consent read is equally contained.
    final broken = CouponAnalyticsClient(
      client: recorder.client(),
      hasSession: (_) => true,
      loadSettings: () async => throw StateError('settings unavailable'),
    );
    await expectLater(broken.recordImpression('c1'), completes);
  });

  test('no authenticated session => nothing is sent (RPC is authenticated-only)',
      () async {
    final recorder = _Recorder();
    final analytics = CouponAnalyticsClient(
      client: recorder.client(),
      hasSession: (_) => false,
      loadSettings: () async => _settings(cloud: ConsentState.accepted),
    );
    await analytics.recordCodeCopy('c1');
    expect(recorder.calls, isEmpty);
  });

  test('K: the payload carries ONLY the coupon id and event name', () async {
    final recorder = _Recorder();
    final analytics = CouponAnalyticsClient(
      client: recorder.client(),
      hasSession: (_) => true,
      loadSettings: () async => _settings(cloud: ConsentState.accepted),
    );
    await analytics.recordCodeCopy('coupon-123');

    final body = recorder.calls.single;
    expect(body.keys.toSet(), {'p_coupon_id', 'p_event'});
    expect(body['p_coupon_id'], 'coupon-123');
    // No identity, country, spend or financial context is ever attached.
    final serialized = jsonEncode(body).toLowerCase();
    for (final forbidden in [
      'install', 'device', 'country', 'category', 'spend', 'amount',
      'transaction', 'balance', 'merchant', 'user_id',
    ]) {
      expect(serialized.contains(forbidden), isFalse, reason: 'leaked $forbidden');
    }
  });
}
