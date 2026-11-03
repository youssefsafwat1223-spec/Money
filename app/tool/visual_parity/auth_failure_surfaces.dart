// Failure-only Apple UI preview. Never returns an identity or calls native auth.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/auth/auth_coordinator.dart';
import 'package:money_companion/core/auth/auth_service.dart';
import 'package:money_companion/core/auth/supabase_auth_service.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';

const visualParityAuthFailureKeys = ['authFailureError', 'authFailureCancel'];
final _events = <String, int>{};
Map<String, int> visualParityAuthFailureEvents() => Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
FailureOnlyAppleAuth? _active;
void releaseVisualParityAuthFailure() => _active?.release();

class FailureOnlyAppleAuth implements AuthService {
  FailureOnlyAppleAuth(this.cancel);
  final bool cancel;
  int calls = 0;
  final gate = Completer<void>();
  void release() {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<AuthIdentity> signInWithApple() async {
    calls++;
    _event(cancel ? 'authFailureCancelAdmitted' : 'authFailureErrorAdmitted');
    await gate.future;
    if (cancel) {
      throw const AuthCancelledException('synthetic_cancel_before_auth');
    }
    throw StateError('private_synthetic_provider_failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_auth_operation');
}

Future<bool> openVisualParityAuthFailure(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityAuthFailureKeys.contains(key)) return false;
  if (!kDebugMode ||
      SupabaseConfig.isConfigured ||
      AuthCoordinator.active != null ||
      AutomaticSessionRecovery.active != null ||
      AppSession.instance.status == SessionStatus.authenticated) {
    throw StateError('auth_preview_requires_no_active_session');
  }
  final databases = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!databases.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('auth_preview_requires_memory');
  }
  if (!context.mounted) return false;
  final service = FailureOnlyAppleAuth(key.endsWith('Cancel'));
  _active = service;
  _event('${key}Opened');
  unawaited(Navigator.of(context)
      .push<void>(MaterialPageRoute<void>(
          builder: (_) => ProviderScope(
              overrides: [authServiceProvider.overrideWithValue(service)],
              child: const OnboardingAuthScreen())))
      .whenComplete(() {
    service.release();
    if (identical(_active, service)) _active = null;
    _event('${key}Closed');
  }));
  return true;
}
