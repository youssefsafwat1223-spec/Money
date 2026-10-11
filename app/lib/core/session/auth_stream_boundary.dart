import 'dart:async';
import 'dart:developer' as developer;

import 'package:supabase_flutter/supabase_flutter.dart';

/// Stream failures lack identity/attempt causality and cannot change authority.
/// `expected` classifies SDK AuthException, not a benign or successful outcome.
class AuthStreamBoundary {
  const AuthStreamBoundary(this.source, {this.reporter});

  final String source;
  final void Function(String source, String origin, String type, bool expected)?
      reporter;

  void onError(Object error, StackTrace stack) => _report('stream', error);

  Future<void> run(FutureOr<void> Function() callback) async {
    try {
      await callback();
    } catch (error) {
      _report('callback', error);
    }
  }

  void _report(String origin, Object error) {
    final expected = error is AuthException;
    final type = error.runtimeType.toString();
    if (reporter != null) {
      reporter!(source, origin, type, expected);
    } else {
      developer.log('$origin failure: $type',
          name: 'auth.$source', level: expected ? 900 : 1000);
    }
  }
}
