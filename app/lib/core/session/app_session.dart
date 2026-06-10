import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  SessionStatus get status => value;

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
    if (email != null) await _storage.write(key: _kEmail, value: email);
    authMethod = method;
    this.email = email;
  }

  /// ينهي الـ onboarding بالكامل → ينتقل للتطبيق.
  Future<void> finishOnboarding() async {
    await _storage.write(key: _kDone, value: '1');
    value = SessionStatus.authenticated;
  }

  /// (توافق) دخول كامل في خطوة واحدة.
  Future<void> completeOnboarding({required String method, String? email}) async {
    await setIdentity(method: method, email: email);
    await finishOnboarding();
  }

  Future<void> signOut() async {
    await _storage.delete(key: _kMethod);
    await _storage.write(key: _kDone, value: '0');
    value = SessionStatus.needsOnboarding;
  }

  /// حذف الحساب وكل البيانات المحلية (Privacy → حذف كل بياناتي).
  Future<void> wipeAndReset() async {
    await _storage.deleteAll();
    authMethod = null;
    email = null;
    value = SessionStatus.needsOnboarding;
  }
}
