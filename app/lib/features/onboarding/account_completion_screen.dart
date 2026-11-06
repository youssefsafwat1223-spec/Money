import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/l10n_ext.dart';
import '../app/app_boot_loader.dart';
import '../common/app_error_state.dart';

/// Verifies the admitted account before routing to setup. A failed lookup can
/// be retried with the current session, without another provider sign-in.
class OnboardingAccountCompletionScreen extends StatefulWidget {
  const OnboardingAccountCompletionScreen({
    super.key,
    required this.client,
  });

  final SupabaseClient client;

  @override
  State<OnboardingAccountCompletionScreen> createState() =>
      _AccountCompletionState();
}

class _AccountCompletionState extends State<OnboardingAccountCompletionScreen> {
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final completed = await AppSession.instance.reconcileAccountOnboarding(
        widget.client,
        requireRemoteResult: true,
      );
      if (mounted) context.go(completed ? '/' : '/onboarding/setup');
    } catch (_) {
      if (!mounted) return;
      final session = widget.client.auth.currentSession;
      if (session == null || session.isExpired) {
        context.go('/onboarding/auth');
      } else {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.colors.bg,
        body: _failed
            ? SafeArea(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: MediaQuery.sizeOf(context).height -
                          MediaQuery.paddingOf(context).vertical,
                    ),
                    child: AppErrorState(
                      title: context.l10n.startFailed,
                      description: context.l10n.onboardingAccountCheckFailed,
                      retryLabel: context.l10n.startRetry,
                      onRetry: _check,
                    ),
                  ),
                ),
              )
            : const AppBootLoader(),
      );
}
