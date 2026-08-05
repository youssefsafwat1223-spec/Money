// MALI-032 — behavioral telemetry-privacy tests.
//
// These are NOT source scans. They build a fully-populated SentryEvent /
// Breadcrumb with a synthetic canary for every sensitive class, run it through
// the real TelemetrySanitizer, serialize the RESULT to JSON exactly as it would
// go on the wire, and assert the canary strings are absent. Positive assertions
// guard against over-redaction destroying triage value.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/observability/privacy_redactor.dart';
import 'package:money_companion/core/observability/telemetry_error.dart';
import 'package:money_companion/core/observability/telemetry_sanitizer.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  // ── One distinctive canary per sensitive class (the audit's list) ─────────
  const rawSms =
      'ACME BANK: purchase 512.34 SAR at STARBUCKSRIYADHCANARY on card 4417883322110099';
  const merchant = 'StarbucksRiyadhCanary';
  const amount = '512.34';
  const account = '4417883322110099';
  const sender = 'AlRajhiCanaryBank';
  const token = 'eyJhbGciOiJIUzI1NiJ9.canarypayloadZZZZ.sigCanaryQQQQ';
  const filePath = '/Users/victimcanary/Documents/report_secret_512.pdf';
  const dbParam =
      "SELECT * FROM txns WHERE amount = 512.34 AND merchant = 'StarbucksRiyadhCanary'";
  const userId = 'user-uuid-canary-1234-abcd';
  const email = 'victim.canary@example.com';
  const username = 'victimcanaryuser';
  const ip = '198.51.100.7';

  const canaries = <String>[
    rawSms,
    merchant,
    amount,
    account,
    sender,
    token,
    filePath,
    dbParam,
    userId,
    email,
    username,
    ip,
  ];

  SentryEvent buildLoadedEvent() {
    final contexts = Contexts()
      ..device = SentryDevice(name: 'iPhoneModelSafe')
      ..['secret_app_context'] = <String, dynamic>{
        'token': token,
        'sms': rawSms,
      };
    return SentryEvent(
      exceptions: <SentryException>[
        // Free-form message + a "cause"-style second entry (db error).
        SentryException(
          type: 'StateError',
          value: 'Bad state while handling: $rawSms (sender=$sender)',
          stackTrace: SentryStackTrace(
            frames: <SentryStackFrame>[
              SentryStackFrame(
                function: 'parseSms',
                fileName: 'parser.dart',
                lineNo: 42,
                vars: <String, dynamic>{
                  'merchant': merchant,
                  'amount': amount,
                  'path': filePath,
                },
              ),
            ],
          ),
        ),
        SentryException(type: 'SqliteException', value: dbParam),
      ],
      message: SentryMessage('report failed for $email: $rawSms'),
      breadcrumbs: <Breadcrumb>[
        Breadcrumb(
          message: rawSms,
          category: 'http',
          type: 'http',
          data: <String, dynamic>{
            'url': 'https://img.logo.dev/$merchant',
            'body': dbParam,
            'account': account,
          },
        ),
      ],
      tags: <String, String>{
        'error.code': TelemetryCodes.syncNetworkTimeout,
        'user_email': email,
        'merchant': merchant,
      },
      extra: <String, dynamic>{
        'error.module': 'sync',
        'sms': rawSms,
        'account': account,
        'nested': <String, dynamic>{'token': token},
      },
      contexts: contexts,
      request: SentryRequest(
        url: 'https://img.logo.dev/$merchant',
        queryString: 'token=$token',
        cookies: 'session=$userId',
        data: rawSms,
        headers: <String, String>{'Authorization': 'Bearer $token'},
        env: <String, String>{'USER': username},
      ),
      user: SentryUser(
        id: userId,
        email: email,
        username: username,
        ipAddress: ip,
      ),
      serverName: 'victimcanary-macbook',
    );
  }

  group('TelemetrySanitizer.sanitizeEvent', () {
    test('no canary from any channel survives into the serialized event', () {
      final sanitized = TelemetrySanitizer.sanitizeEvent(buildLoadedEvent());
      final wire = jsonEncode(sanitized.toJson());
      for (final canary in canaries) {
        expect(
          wire.contains(canary),
          isFalse,
          reason: 'canary "$canary" leaked into the outbound telemetry event',
        );
      }
    });

    test('triage signal is preserved (not over-redacted)', () {
      final sanitized = TelemetrySanitizer.sanitizeEvent(buildLoadedEvent());
      final wire = jsonEncode(sanitized.toJson());

      // Exception class names survive; their free-form messages do not.
      expect(sanitized.exceptions![0].type, 'StateError');
      expect(sanitized.exceptions![0].value, PrivacyRedactor.redacted);
      expect(sanitized.exceptions![1].value, PrivacyRedactor.redacted);

      // Stack frame code locations survive; captured vars do not.
      expect(sanitized.exceptions![0].stackTrace!.frames.first.function,
          'parseSms');
      expect(sanitized.exceptions![0].stackTrace!.frames.first.vars, isEmpty);

      // Allowlisted structured fields survive; everything else is gone.
      expect(sanitized.tags!['error.code'], TelemetryCodes.syncNetworkTimeout);
      expect(sanitized.tags!.containsKey('user_email'), isFalse);
      expect(sanitized.tags!.containsKey('merchant'), isFalse);
      expect(sanitized.extra!['error.module'], 'sync');
      expect(sanitized.extra!.containsKey('sms'), isFalse);

      // Standard device context survives; the custom app context is dropped.
      expect(wire.contains('iPhoneModelSafe'), isTrue);
      expect(sanitized.contexts.containsKey('secret_app_context'), isFalse);

      // Breadcrumbs / request / user are cleared wholesale.
      expect(sanitized.breadcrumbs, isEmpty);
      expect(sanitized.request!.url, isNull);
      expect(sanitized.user!.id, PrivacyRedactor.redacted);
      expect(sanitized.user!.email, isNull);
      expect(sanitized.user!.ipAddress, isNull);
    });

    test('a structured TelemetryError surfaces its stable code, not its text',
        () {
      final event = SentryEvent(
        exceptions: <SentryException>[
          SentryException(
            type: 'TelemetryError',
            value: 'decrypt failed for $rawSms',
            throwable:
                const TelemetryError(TelemetryCodes.storageDecryptFailed),
          ),
        ],
      );
      final sanitized = TelemetrySanitizer.sanitizeEvent(event);
      expect(
        sanitized.exceptions![0].value,
        TelemetryCodes.storageDecryptFailed,
      );
      expect(
        jsonEncode(sanitized.toJson()).contains(rawSms),
        isFalse,
      );
    });
  });

  group('TelemetrySanitizer.sanitizeBreadcrumb', () {
    test('drops message + data but keeps the crumb shape', () {
      final crumb = Breadcrumb(
        message: rawSms,
        category: 'navigation',
        type: 'navigation',
        data: <String, dynamic>{
          'to': '/txn/$account',
          'merchant': merchant,
          'file': filePath,
        },
      );
      final sanitized = TelemetrySanitizer.sanitizeBreadcrumb(crumb)!;
      final wire = jsonEncode(sanitized.toJson());
      for (final canary in canaries) {
        expect(wire.contains(canary), isFalse,
            reason: 'canary "$canary" leaked into a breadcrumb');
      }
      expect(sanitized.category, 'navigation');
      expect(sanitized.type, 'navigation');
    });

    test('passes null through unchanged', () {
      expect(TelemetrySanitizer.sanitizeBreadcrumb(null), isNull);
    });
  });

  group('PrivacyRedactor.redactText', () {
    test('strips structured PII classes it is responsible for', () {
      final out = PrivacyRedactor.redactText(
        'paid 512.34 to card 4417883322110099, token eyJabc.def.ghi '
        'at $email path /Users/x/report.pdf',
      );
      expect(out.contains('512.34'), isFalse);
      expect(out.contains('4417883322110099'), isFalse);
      expect(out.contains('eyJabc.def.ghi'), isFalse);
      expect(out.contains(email), isFalse);
      expect(out.contains('/Users/x/report.pdf'), isFalse);
    });
  });
}
