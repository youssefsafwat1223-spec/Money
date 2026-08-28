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
    'core/backup/supabase_remote_backup_store.dart':
        'EgressClass.backup — gated by its CALLER, RemoteBackupController',
    'core/backup/encrypted_backup_service.dart':
        'EgressClass.backup — gated by its CALLER, RemoteBackupController',
  };

  /// Where the gate lives, when it is not in the egress file itself.
  ///
  /// A store that performs the upload is not always the right place to ask the
  /// question — the backup store is driven exclusively by
  /// `RemoteBackupController`, which is where the consent decision belongs.
  /// Recording the indirection keeps the check honest instead of loosening it.
  const gatedByCaller = <String, String>{
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
    'data/catalog/catalog_sync_service.dart':
        'EXEMPT: catalog carries no user data, and delivers parser rules, '
            'feature flags and the force-update kill switch. Gating it would '
            'disable safety controls for the most privacy-conscious users.',
    'data/catalog/merchant_feedback_client.dart':
        'OPEN (C-3 remainder): user-derived merchant keywords, belongs on '
            'EgressClass.aiProcessing. Currently UNWIRED — no caller exists in '
            'lib/, so it cannot leak today; gate it when it is wired.',
    'features/capture/services/smart_inbox_sync_service.dart':
        'OPEN (C-3 remainder): EgressClass.smartInbox. Its pull gate is a '
            'hardcoded () => true.',
    'features/planning_sync/services/accounts_pull_service.dart':
        'OPEN + QUARANTINED: financial PULL. The file is in the H-4 quarantine '
            '(see QIRSH_MASTER_PLAN_V2.md §8a), so it cannot be gated until '
            'that workstream lands.',
    'features/planning_sync/services/planning_pull_service.dart':
        'OPEN + QUARANTINED: financial PULL, same quarantine.',
    'features/planning_sync/services/planning_child_sync_service.dart':
        'OPEN + QUARANTINED: financial PULL, same quarantine.',
  };

  test('every file that reaches the network is a listed decision', () {
    final egressCall = RegExp(
      r"functions\.invoke|\.storage\.from\(|http\.post|http\.get|"
      r"client\.from\(|_client\.from\(|supabase\.from\(|instance\.client\.from\(",
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
      final gatedHere = src.contains('mayEgress') ||
          src.contains('ConsentAuthority') ||
          src.contains('consentGranted');
      expect(gatedHere, isTrue,
          reason: '$path is listed as gated, but its gate file $gateFile '
              'references no consent check');
    }
  });
}
