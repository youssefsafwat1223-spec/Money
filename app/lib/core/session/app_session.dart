import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../tracking/user_activity_service.dart';

enum SessionStatus { unknown, needsOnboarding, authenticated }

/// حالة الجلسة (للتحكّم في عرض الـ Onboarding مقابل التطبيق).
///
/// ValueNotifier حتى يُستخدم كـ refreshListenable في go_router دون Riverpod.
/// تُخزَّن الأعلام في flutter_secure_storage (لا بيانات مالية هنا).
class AppSession extends ValueNotifier<SessionStatus> {
  AppSession._() : super(SessionStatus.unknown);

  static final AppSession instance = AppSession._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _kDone = 'onboarding_done';
  static const String _kMethod = 'auth_method';
  static const String _kEmail = 'auth_email';

  String? authMethod;
  String? email;
  StreamSubscription<supabase.AuthState>? _supabaseAuthSubscription;

  SessionStatus get status => value;
  bool get isGuest => authMethod == 'guest';

  Future<void> load() async {
    final done = await _storage.read(key: _kDone);
    authMethod = await _storage.read(key: _kMethod);
    email = await _storage.read(key: _kEmail);
    value = done == '1'
        ? SessionStatus.authenticated
        : SessionStatus.needsOnboarding;
  }

  /// يخزّن هوية الدخول دون إنهاء الـ onboarding (تبقى خطوة الطريقة بعدها).
  Future<void> setIdentity({required String method, String? email}) async {
    await _storage.write(key: _kMethod, value: method);
    if (email != null && email.trim().isNotEmpty) {
      await _storage.write(key: _kEmail, value: email);
    } else if (method == 'guest') {
      await _storage.delete(key: _kEmail);
    }
    authMethod = method;
    this.email = email;
  }

  /// ينهي الـ onboarding بالكامل → ينتقل للتطبيق.
  Future<void> finishOnboarding() async {
    authMethod ??= await _storage.read(key: _kMethod);
    await _storage.write(key: _kDone, value: '1');
    value = SessionStatus.authenticated;
    unawaited(UserActivityService.onSignIn());
  }

  Future<void> continueAsGuest() async {
    await setIdentity(method: 'guest');
    await finishOnboarding();
  }

  /// (توافق) دخول كامل في خطوة واحدة.
  Future<void> completeOnboarding(
      {required String method, String? email}) async {
    await setIdentity(method: method, email: email);
    await finishOnboarding();
  }

  Future<void> signOut() async {
    UserActivityService.onSignOut();
    await _storage.delete(key: _kMethod);
    await _storage.delete(key: _kEmail);
    await _storage.write(key: _kDone, value: '0');
    authMethod = null;
    email = null;
    value = SessionStatus.needsOnboarding;
  }

  Future<void> bindSupabaseAuth(supabase.SupabaseClient client) async {
    _supabaseAuthSubscription ??=
        client.auth.onAuthStateChange.listen(_handleSupabaseAuthChange);
    await _reconcileSupabaseSession(client.auth.currentSession);
  }

  Future<void> _handleSupabaseAuthChange(supabase.AuthState state) async {
    switch (state.event) {
      case supabase.AuthChangeEvent.signedOut:
      case supabase.AuthChangeEvent.userDeleted:
        if (!isGuest && authMethod != null) {
          await signOut();
        }
        return;
      case supabase.AuthChangeEvent.initialSession:
      case supabase.AuthChangeEvent.signedIn:
      case supabase.AuthChangeEvent.tokenRefreshed:
      case supabase.AuthChangeEvent.userUpdated:
        await _reconcileSupabaseSession(state.session);
        return;
      case supabase.AuthChangeEvent.passwordRecovery:
      case supabase.AuthChangeEvent.mfaChallengeVerified:
        return;
    }
  }

  Future<void> _reconcileSupabaseSession(supabase.Session? session) async {
    if (isGuest || authMethod == null) return;
    if (value == SessionStatus.authenticated && session == null) {
      await signOut();
      return;
    }
    final remoteEmail = session?.user.email;
    if (remoteEmail == null || remoteEmail.trim().isEmpty) return;
    if (remoteEmail == email) return;
    email = remoteEmail;
    await _storage.write(key: _kEmail, value: remoteEmail);
    notifyListeners();
  }

  /// حذف الحساب وكل البيانات المحلية (Privacy → حذف كل بياناتي).
  Future<void> wipeAndReset() async {
    await _storage.deleteAll();
    authMethod = null;
    email = null;
    value = SessionStatus.needsOnboarding;
  }
}
