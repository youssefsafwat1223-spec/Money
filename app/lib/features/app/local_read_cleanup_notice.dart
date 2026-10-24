import 'package:flutter/material.dart';

import '../../core/session/app_session.dart';
import '../../l10n/app_localizations.dart';

/// Honest outcome of an incomplete logout: the device IS signed out and the
/// process stays locked, but the durable offline lock could not be written, so a
/// restart is not guaranteed to stay locked. Shown from the ROOT navigator
/// (captured before signing out): the screen that started the logout is disposed
/// by the scope swap. Retry re-runs only the durable deny; nothing is deleted.
Future<void> showSignOutIncompleteNotice(
  NavigatorState navigator,
  AppL10n l10n, {
  Future<bool> Function()? retry,
}) {
  final rerun = retry ?? AppSession.instance.retryLocalReadDeny;
  return showDialog<void>(
    context: navigator.context,
    builder: (dialogContext) {
      var message = l10n.signOutCleanupIncompleteMessage;
      var busy = false;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          key: const Key('sign_out_incomplete_notice'),
          content: Text(message, key: const Key('sign_out_incomplete_message')),
          actions: [
            TextButton(
              key: const Key('sign_out_incomplete_retry'),
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      var done = false;
                      try {
                        done = await rerun();
                      } catch (_) {
                        done = false;
                      }
                      if (!dialogContext.mounted) return;
                      if (done) {
                        Navigator.of(dialogContext).pop();
                      } else {
                        setState(() {
                          busy = false;
                          message = l10n.signOutCleanupStillIncomplete;
                        });
                      }
                    },
              child: Text(l10n.signOutCleanupRetry),
            ),
            TextButton(
              key: const Key('sign_out_incomplete_close'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.commonClose),
            ),
          ],
        ),
      );
    },
  );
}

/// Astra D4 / R10.3: the ROOT-level notice for a removal request whose durable
/// offline-access denial is unestablished. It sits above the router (like the
/// data-removed notice host), so the screen that started the removal being
/// disposed by the scope swap cannot lose it. It says only the denial fact: this
/// is raised whether the removal returned, threw or had no target, so it never
/// claims data was removed (the separate data-removed notice does that, only for
/// a confirmed removal) and never promises that a restart finishes the denial.
/// Retry re-runs ONLY the durable deny ([AppSession.retryLocalReadDeny]); it never
/// repeats the removal, the key deletion or any remote effect.
class DenyIncompleteNoticeHost extends StatefulWidget {
  const DenyIncompleteNoticeHost({super.key, this.retry});

  /// Test seam; the default is the real durable-deny retry.
  final Future<bool> Function()? retry;

  @override
  State<DenyIncompleteNoticeHost> createState() =>
      _DenyIncompleteNoticeHostState();
}

class _DenyIncompleteNoticeHostState extends State<DenyIncompleteNoticeHost> {
  final _pending = AppSession.instance.denyIncompleteNoticePending;
  bool _busy = false;
  bool _stillIncomplete = false;

  @override
  void initState() {
    super.initState();
    _pending.addListener(_changed);
  }

  @override
  void dispose() {
    _pending.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!_pending.value) _stillIncomplete = false;
    setState(() {});
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    var done = false;
    try {
      done = await (widget.retry ?? AppSession.instance.retryLocalReadDeny)();
    } catch (_) {
      done = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _stillIncomplete = !done;
    });
    if (done) _pending.value = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_pending.value) return const SizedBox.shrink();
    final l10n = AppL10n.of(context);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Material(
            key: const Key('deny_incomplete_notice'),
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _stillIncomplete
                        ? l10n.removeDataDenyStillIncomplete
                        : l10n.removeDataDenyIncompleteMessage,
                    key: const Key('deny_incomplete_message'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const Key('deny_incomplete_retry'),
                        onPressed: _busy ? null : _retry,
                        child: Text(l10n.signOutCleanupRetry),
                      ),
                      TextButton(
                        key: const Key('deny_incomplete_close'),
                        onPressed:
                            _busy ? null : () => _pending.value = false,
                        child: Text(l10n.commonClose),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
