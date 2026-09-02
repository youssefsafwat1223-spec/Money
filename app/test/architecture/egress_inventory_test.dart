import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// C-3 / R-1 — no new network egress without a consent decision.
///
/// ## Why a structural test and not only unit tests
/// The root cause of F-025 was never a missing check in one place. It was that
/// consent enforcement was **per-service opt-in**, so every new service shipped
/// ungated by default — and several did. Two found in review, both shipped:
///
///   * `RemoteBackupController` defaulted its consent callback to `() => true`
///     and the provider never passed one, so the encrypted backup uploaded with
///     cloud consent OFF;
///   * the Smart Inbox pull gate is a hardcoded `isPullEnabled: () => true`.
///
/// Unit tests prove the gates that EXIST work. Only an inventory test can catch
/// the next service that forgets one. This is the R-1 structural remedy: every
/// file that talks to the network must be a deliberate, listed decision.
///
/// ## How to satisfy it when it fails
/// Adding egress to a new file will fail this test. That is the point. Either
/// gate the call through `ConsentAuthority` and add the file to [_gated], or —
/// if it genuinely carries no user data — add it to [_ungatedByDesign] WITH the
/// reason. Do not add a file to the ungated list to make the test pass.
void main() {
  /// Files whose egress is gated on consent, and where.
  const gated = <String, String>{
    'data/sync/sender_bank_mapping_sync_service.dart':
        'EgressClass.senderBankMappings — which banks the user holds',
    'features/planning_sync/services/accounts_push_service.dart':
        'EgressClass.financialSync — money',
    'features/capture/services/ledger_push_service.dart':
        'EgressClass.financialSync — money',
    'features/capture/services/notification_log_sync_service.dart':
        'EgressClass.telemetry — notification delivery/open events',
    'features/capture/services/smart_inbox_sync_service.dart':
        'EgressClass.smartInbox — its isPullEnabled is a FEATURE gate, '
            'hardcoded open; consent is asked separately',
    'data/catalog/merchant_feedback_client.dart':
        'EgressClass.aiProcessing — user-derived merchant keywords. Unwired '
            'today; gated now so whoever wires it must pass consent',
    'features/planning_sync/services/accounts_pull_service.dart':
        'EgressClass.financialSync — money DOWN; a pull also WRITES locally',
    'features/planning_sync/services/planning_pull_service.dart':
        'EgressClass.financialSync — gated once per pull, not per entity',
    'features/planning_sync/services/planning_child_sync_service.dart':
        'EgressClass.financialSync — consent precedes the capability gate',
    'features/planning_sync/services/accounts_backfill_service.dart':
        'EgressClass.financialSync — money. Gated by its CALLER, '
            'StartupSyncReconcileService, whose single check covers every '
            'backfill it drives. Was an OPEN finding until 2026-09-02: it '
            'gated on transport capability and never on consent.',
    'core/backup/supabase_remote_backup_store.dart':
        'EgressClass.backup — gated by its CALLER, RemoteBackupController',
    'core/backup/encrypted_backup_service.dart':
        'EgressClass.backup — gated by its CALLER, RemoteBackupController',
    'features/coupons/coupon_analytics.dart':
        'cloudProcessingEnabled, re-read per send (coupon_analytics.dart:99) — '
            'record_coupon_event carries a coupon id and an event name and no '
            'financial context. Surfaced only when this guard learned to see '
            '`.rpc<T>(`; it was correctly gated the whole time, but nothing '
            'was enforcing that.',
  };

  /// Where the gate lives, when it is not in the egress file itself.
  ///
  /// A store that performs the upload is not always the right place to ask the
  /// question — the backup store is driven exclusively by
  /// `RemoteBackupController`, which is where the consent decision belongs.
  /// Recording the indirection keeps the check honest instead of loosening it.
  const gatedByCaller = <String, String>{
    // CLOSED 2026-09-02 (was an OPEN finding). The backfills reached from
    // StartupSyncReconcileService gated on TRANSPORT capability and never on
    // consent, while every sibling push/pull service in the same pipeline
    // asked. A transport gate answers "can we send this safely"; it does not
    // answer "may we". ONE gate at the reconcile entry covers every backfill it
    // drives, and it defaults to DENY.
    'features/planning_sync/services/accounts_backfill_service.dart':
        'features/planning_sync/services/startup_sync_reconcile_service.dart',
    'core/backup/supabase_remote_backup_store.dart':
        'core/backup/remote_backup_controller.dart',
    'core/backup/encrypted_backup_service.dart':
        'core/backup/remote_backup_controller.dart',
  };

  /// Files that reach the network WITHOUT a consent gate, each with the reason.
  ///
  /// Everything here is either genuinely consent-exempt, or an OPEN finding
  /// that is tracked rather than hidden. The distinction is stated per entry so
  /// nobody has to guess which is which.
  const ungatedByDesign = <String, String>{
    // ── Surfaced when `.rpc[<(]` was added to the pattern below ────────────
    //
    // Five call sites had been invisible to this guard since it was written:
    // the regex matched `functions.invoke` and `.from(` but not `.rpc(`, and
    // not `.rpc<void>(` even after the first widening. Each is classified here
    // on its merits. Two are OPEN FINDINGS, recorded rather than papered over.
    'core/auth/account_deletion_service.dart':
        'EXEMPT: request_account_deletion / cancel_account_deletion. Deletion '
            'must work regardless of consent state — gating the exit behind the '
            'permission would trap a user who wants their data gone. Carries no '
            'payload beyond the authenticated identity.',
    'core/session/app_session.dart':
        'EXEMPT: mark_onboarding_completed takes no parameters, is guarded on a '
            'live session and a non-guest account, and records account state '
            'rather than anything derived from the user.',
    'features/referrals/services/referral_service.dart':
        'EXEMPT: authenticated referral RPCs (0083), every one user-initiated. '
            'The only payload is a referral code the user typed. Server-side '
            'rules enforce qualification independently.',
    'core/backend/metrics_client.dart':
        'OPEN FINDING — not exempt. record_metric is best-effort product '
            'telemetry with NO consent gate. Mitigated but not resolved: the '
            'RPC is owner-bound, allowlisted and rate-limited server-side '
            '(MALI-075n), unknown keys are silent no-ops, and it sends a key '
            'plus a coarse dimension rather than user data. It is awaited from '
            'bootstrap, so a consent read there would need to survive a cold '
            'start with no settings loaded. Tracked, not hidden.',

    'features/gamification/services/engagement_event_service.dart':
        'OPEN FINDING — unwired, not exempt. SupabaseEngagementRecorder is '
            'declared but instantiated nowhere in lib/; grep finds no caller, '
            'so nothing reaches the network today. EgressClass.gamification '
            'already exists in ConsentAuthority and returns the cloud decision, '
            'so whoever wires this must gate it there and move this entry into '
            '`gated`. Listed the same way merchant_feedback_client.dart is, so '
            'the obligation is visible before the first caller appears.',
    'data/catalog/catalog_sync_service.dart':
        'EXEMPT: catalog carries no user data, and delivers parser rules, '
            'feature flags and the force-update kill switch. Gating it would '
            'disable safety controls for the most privacy-conscious users.',
  };

  test('every file that reaches the network is a listed decision', () {
    final egressCall = RegExp(
      r"functions\.invoke|\.storage\.from\(|http\.post|http\.get|"
      r"client\.from\(|_client\.from\(|supabase\.from\(|instance\.client\.from\(|"
      // COUPONS Phase 1 — `.rpc(` was a structural blind spot. A Supabase RPC
      // is a network call like any other, and coupon_analytics.dart has been
      // making one (`record_coupon_event`) that this guard could not see. Any
      // future RPC — an affiliate click, a status poll — would have been
      // equally invisible.
      r"\.rpc[<(]",
    );

    final found = <String>{};
    void walk(Directory dir) {
      for (final e in dir.listSync()) {
        if (e is Directory) {
          walk(e);
        } else if (e is File && e.path.endsWith('.dart')) {
          if (egressCall.hasMatch(e.readAsStringSync())) {
            found.add(e.path.replaceFirst('lib/', ''));
          }
        }
      }
    }

    walk(Directory('lib'));

    final known = {...gated.keys, ...ungatedByDesign.keys};
    final unlisted = found.difference(known);

    expect(
      unlisted,
      isEmpty,
      reason: 'New network egress found in files that make no consent '
          'decision:\n  ${unlisted.join('\n  ')}\n\n'
          'Gate it through ConsentAuthority and add it to `gated`, or add it '
          'to `ungatedByDesign` WITH the reason it is exempt. Do NOT add a '
          'file to the ungated list merely to make this test pass — that is '
          'the per-service opt-in habit this test exists to break.',
    );
  });

  test('the listed files still exist — the inventory cannot go stale', () {
    for (final path in {...gated.keys, ...ungatedByDesign.keys}) {
      expect(File('lib/$path').existsSync(), isTrue,
          reason: '$path is listed but no longer exists; prune the inventory');
    }
  });

  test('every ungated entry states a reason, and open ones say so', () {
    for (final entry in ungatedByDesign.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: entry.key);
      expect(
        entry.value.startsWith('EXEMPT') || entry.value.startsWith('OPEN'),
        isTrue,
        reason: '${entry.key}: an ungated egress must be classified either '
            'EXEMPT (carries no user data) or OPEN (a tracked finding). '
            '"Undecided" is how ungated egress ships.',
      );
    }
  });

  test('the gated files actually reference the consent authority', () {
    // A file listed as gated that never consults consent would make this
    // inventory a comfortable fiction.
    for (final path in gated.keys) {
      // Check the file that actually holds the gate — which is the caller for
      // the backup store.
      final gateFile = gatedByCaller[path] ?? path;
      final src = File('lib/$gateFile').readAsStringSync();
      // `cloudProcessingEnabled` counts as a real gate, not a loophole: it is
      // the same effective grant ConsentAuthority derives its decision from,
      // and for a telemetry-class call the authority returns exactly that
      // value. Routing through the authority is still preferable — one place to
      // change the policy — so a new call site should use it rather than this.
      final gatedHere = src.contains('mayEgress') ||
          src.contains('ConsentAuthority') ||
          src.contains('consentGranted') ||
          src.contains('cloudProcessingEnabled');
      expect(gatedHere, isTrue,
          reason: '$path is listed as gated, but its gate file $gateFile '
              'references no consent check');
    }
  });
}
