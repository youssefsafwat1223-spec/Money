// Offline QA only. Typed status inputs, never actual logout or durable denial.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/session/app_session.dart'
    show SignOutOutcome;
import 'package:money_companion/features/app/local_read_shell.dart';

const visualParityLocalReadNoticeKeys = <String>[
  'localReadCleanupRetryPending',
  'localReadCleanupRetryFalse',
  'localReadCleanupRetryError',
];
final _events = <String, int>{};
Map<String, int> visualParityLocalReadNoticeEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);

Future<bool> openVisualParityLocalReadNotice(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityLocalReadNoticeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('local_read_notice_requires_offline_debug');
  }
  final database = ref.read(appDatabaseProvider);
  final rows = await database.customSelect('PRAGMA database_list').get();
  if (!rows.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('local_read_notice_requires_memory_database');
  }
  if (!context.mounted) return false;
  final container = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(database),
    localeProvider.overrideWithValue(Localizations.localeOf(context)),
  ]);
  _event('${key}Opened');
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => _LocalReadNoticeHost(container: container, keyName: key),
  )));
  return true;
}

class _LocalReadNoticeHost extends StatefulWidget {
  const _LocalReadNoticeHost({required this.container, required this.keyName});
  final ProviderContainer container;
  final String keyName;
  @override
  State<_LocalReadNoticeHost> createState() => _LocalReadNoticeHostState();
}

class _LocalReadNoticeHostState extends State<_LocalReadNoticeHost> {
  final _pendingRetry = Completer<bool>();
  @override
  void dispose() {
    if (!_pendingRetry.isCompleted) _pendingRetry.complete(false);
    widget.container.dispose();
    _event('${widget.keyName}Closed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
        container: widget.container,
        child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => LocalReadShell(
                    onReconnect: () {
                      _event('localReadNoticeForbiddenReconnect');
                      throw StateError('local_read_notice_reconnect_forbidden');
                    },
                    // Deliberately do not override onLogout: public Logout runs unchanged
                    // _logout and opens the actual notice from this typed status input.
                    signOutAction: () async {
                      _event('${widget.keyName}LogoutStatusInput');
                      return SignOutOutcome.durableDenyIncomplete;
                    },
                    retryDeny: () {
                      _event('${widget.keyName}RetryStatusInput');
                      if (widget.keyName.endsWith('Pending')) {
                        return _pendingRetry.future;
                      }
                      if (widget.keyName.endsWith('Error')) {
                        return Future<bool>.error(
                            StateError('private_local_read_retry_failure'));
                      }
                      return Future<bool>.value(false);
                    },
                  ),
                )),
      );
}
