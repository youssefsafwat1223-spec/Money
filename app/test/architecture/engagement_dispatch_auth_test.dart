import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Migration-level guard for the engagement dispatch auth contract (0098).
///
/// The Deno tests in supabase/functions/*/auth_test.ts prove the RECEIVING half
/// (each Edge Function rejects everything but its own dedicated secret). This
/// pins the SENDING half, which lives in SQL and has no runtime test here: the
/// dispatcher must present the dedicated worker secret, must fail closed when
/// it is absent, and must never reach for `service_role_key` again.
///
/// Source-level on purpose. These are claims about what the migration corpus
/// CONTAINS — "no dispatcher reads service_role_key any more" is the absence of
/// a code path, which no runtime test over a single execution can establish.
void main() {
  final migrations = Directory('../supabase/migrations');
  String latestDefinitionOf(String fnName) {
    // The effective definition is the one in the HIGHEST-numbered migration
    // that redefines it — exactly what a fresh apply ends up with. Reading only
    // 0098 would pass even if a later migration reintroduced the old pattern.
    final files = migrations.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    var found = '';
    for (final f in files) {
      final text = f.readAsStringSync();
      // Must be the DEFINITION, not a `REVOKE ... ON FUNCTION name()` line —
      // matching those captured the trailing postcondition block instead.
      //
      // Case-insensitive and `public.`-tolerant: 0066 already uses lowercase
      // `create or replace function public.name()`, so a later migration in
      // that style would otherwise be invisible here and this guard would keep
      // passing against a stale definition.
      final marker = RegExp(
        'create\\s+or\\s+replace\\s+function\\s+(public\\.)?$fnName\\s*\\(\\s*\\)',
        caseSensitive: false,
      );
      for (final m in marker.allMatches(text)) {
        final end = text.indexOf(RegExp(r'\$\$;'), m.start);
        if (end != -1) found = text.substring(m.start, end);
      }
    }
    return found;
  }

  const dispatchers = {
    'trigger_evaluate_budgets': 'engagement_worker_secret',
    'trigger_evaluate_gamification': 'engagement_worker_secret',
    'trigger_evaluate_goals': 'engagement_worker_secret',
    'run_cron_daily_reminders': 'reminders_worker_secret',
  };

  group('the engagement dispatchers use dedicated worker secrets', () {
    test('every dispatcher exists in the migration corpus', () {
      for (final fn in dispatchers.keys) {
        expect(latestDefinitionOf(fn), isNotEmpty,
            reason: '$fn has no definition in supabase/migrations');
      }
    });

    test('none of them reads service_role_key any more', () {
      // The deprecated contract. SUPABASE_SERVICE_ROLE_KEY is platform-reserved
      // and its value differs from the real service-role JWT, so a dispatcher
      // presenting it can never be authorised — the bug 0098 fixes.
      for (final fn in dispatchers.keys) {
        expect(latestDefinitionOf(fn).contains('service_role_key'), isFalse,
            reason: '$fn still reads the deprecated service_role_key');
      }
    });

    test('each reads its own dedicated secret', () {
      dispatchers.forEach((fn, secret) {
        expect(latestDefinitionOf(fn), contains(secret),
            reason: '$fn must read $secret');
      });
    });

    test('the retired reminders endpoint does NOT hold the engagement secret', () {
      // Least privilege where it actually buys something: cron-daily-reminders
      // is a no-op with no data access and must not carry a credential that
      // unlocks the three live engagement functions.
      expect(
        latestDefinitionOf('run_cron_daily_reminders')
            .contains('engagement_worker_secret'),
        isFalse,
      );
    });

    test('each still reads project_url and fails closed when config is absent', () {
      for (final fn in dispatchers.keys) {
        final def = latestDefinitionOf(fn);
        expect(def, contains('project_url'), reason: '$fn lost project_url');
        expect(def, contains('IS NULL'),
            reason: '$fn lost its fail-closed NULL guard');
        expect(def, contains('RAISE LOG'),
            reason: '$fn must log the skip rather than fail silently');
      }
    });

    test('no dispatcher falls back to another credential when its secret is absent', () {
      // A fallback would defeat the whole point: absent config must mean no
      // request, not a request with whatever else is lying around.
      for (final fn in dispatchers.keys) {
        final def = latestDefinitionOf(fn);
        final nullGuard = def.indexOf('IS NULL');
        final post = def.indexOf('net.http_post');
        expect(nullGuard, lessThan(post),
            reason: '$fn posts before checking its configuration');
      }
    });
  });

  group('0098 preserves the existing wiring', () {
    final m0098raw = File(
      '../supabase/migrations/0098_engagement_worker_secret_auth.sql',
    ).readAsStringSync();
    // Strip SQL line comments: the rationale prose legitimately NAMES the
    // things the migration promises not to call.
    final m0098 = m0098raw
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('--'))
        .join('\n');

    test('it does not touch cron.schedule or drop any trigger', () {
      // Behaviour must be unchanged: only the credential changes.
      expect(m0098.contains('cron.schedule'), isFalse,
          reason: '0098 must not reschedule anything');
      expect(m0098.contains('cron.unschedule'), isFalse);
      expect(m0098.contains('DROP TRIGGER'), isFalse,
          reason: '0098 must not recreate triggers');
    });

    test('it asserts its own postconditions', () {
      expect(m0098, contains('0098 postcondition'));
      for (final fn in dispatchers.keys) {
        expect(m0098, contains(fn));
      }
    });

    test('it carries none of the DEFERRED migration\'s content', () {
      // supabase/deferred/0098_record_metric_ad_keys.sql shares this number:
      // per supabase/deferred/README.md a deferred file does NOT reserve its
      // number, and renumbers to the tail when reactivated. Sharing the number
      // is expected; sharing the CONTENT would mean accidentally activating
      // telemetry that is deliberately switched off.
      expect(m0098.contains('record_metric'), isFalse);
      expect(m0098.contains('report_export'), isFalse);
      expect(m0098.toLowerCase().contains('allowlist'), isFalse);
    });

    test('the payloads are byte-identical to 0057 — credentials only', () {
      // Codex caught this: the first draft added an `old_record` key to the
      // goals and gamification payloads. 0057 sends neither, and no Edge
      // function reads one, so it was a silent contract change inside a
      // migration whose whole claim is that it touches credentials only.
      String payloadOf(String file, String fn) {
        final text = File('../supabase/migrations/$file').readAsStringSync();
        final start = text.indexOf('CREATE OR REPLACE FUNCTION $fn()');
        expect(start, isNot(-1), reason: '$fn not found in $file');
        final body = text.substring(start);
        final pi = body.indexOf('payload := jsonb_build_object(');
        if (pi == -1) return '';
        final close = body.indexOf(');', pi);
        return body
            .substring(pi, close)
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty && !l.startsWith('--'))
            .join(' ');
      }

      for (final fn in [
        'trigger_evaluate_budgets',
        'trigger_evaluate_gamification',
        'trigger_evaluate_goals',
      ]) {
        expect(
          payloadOf('0098_engagement_worker_secret_auth.sql', fn),
          payloadOf('0057_engagement_webhooks.sql', fn),
          reason: '$fn payload drifted from 0057 — 0098 must change credentials only',
        );
      }
    });

    test('the trigger postconditions assert the target function, not just the name', () {
      // A trigger repointed at a different function would otherwise pass.
      expect(m0098, contains('t.tgfoid'));
      for (final fn in [
        'trigger_evaluate_budgets',
        'trigger_evaluate_gamification',
        'trigger_evaluate_goals',
      ]) {
        expect(m0098, contains("p.proname = '$fn'"));
      }
    });

    test('it has a rollback', () {
      expect(
        File('../supabase/rollback/0098_engagement_worker_secret_auth_rollback.sql')
            .existsSync(),
        isTrue,
      );
    });
  });

  group('the Edge half matches the SQL half', () {
    const edge = {
      'evaluate-budgets': 'ENGAGEMENT_WORKER_SECRET',
      'evaluate-goals': 'ENGAGEMENT_WORKER_SECRET',
      'evaluate-gamification': 'ENGAGEMENT_WORKER_SECRET',
      'cron-daily-reminders': 'REMINDERS_WORKER_SECRET',
    };

    test('each function compares against its dedicated env var', () {
      edge.forEach((fn, env) {
        final src = File('../supabase/functions/$fn/index.ts').readAsStringSync();
        expect(src, contains("Deno.env.get('$env')"),
            reason: '$fn must read $env');
        expect(src, contains('timingSafeEqual'),
            reason: '$fn must compare in constant time');
      });
    });

    test('no function still AUTHENTICATES with SUPABASE_SERVICE_ROLE_KEY', () {
      // The service-role key legitimately remains for CONSTRUCTING the Supabase
      // client; what must not remain is comparing the caller's bearer to it.
      edge.forEach((fn, _) {
        final src = File('../supabase/functions/$fn/index.ts').readAsStringSync();
        expect(
          src.contains("timingSafeEqual(token, serviceKey)"),
          isFalse,
          reason: '$fn still authenticates against the platform-reserved key',
        );
      });
    });
  });
}
