import 'package:flutter/foundation.dart';
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

/// أخطاء طبقة المستودعات (Repository) — تُستخدم لتمييز فشل الشبكة عن فشل
/// التحقق عن رفض RLS عن تعارض القيم الفريدة، حتى تعرض الواجهة رسالة دقيقة
/// بدل رسالة عامة.
sealed class RepoException implements Exception {
  const RepoException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class NetworkRepoException extends RepoException {
  const NetworkRepoException([super.message = 'network_error']);
}

class AuthRepoException extends RepoException {
  const AuthRepoException([super.message = 'auth_required']);
}

class ValidationRepoException extends RepoException {
  const ValidationRepoException([super.message = 'validation_failed']);
}

class ForbiddenRepoException extends RepoException {
  const ForbiddenRepoException([super.message = 'forbidden']);
}

class DuplicateRepoException extends RepoException {
  const DuplicateRepoException([super.message = 'duplicate']);
}

/// عملية استهدفت صفًا محددًا لم تُطابق أي صف — إما أنه غير موجود أو لا
/// يخص المستخدم الحالي؛ RLS تتعمّد عدم التمييز بين الحالتين لمن لا يملك
/// الصف، لذا تُعامَل الحالتان كـ NotFound وليس Forbidden.
class NotFoundRepoException extends RepoException {
  const NotFoundRepoException([super.message = 'not_found']);
}

class ServerRepoException extends RepoException {
  const ServerRepoException([super.message = 'server_error']);
}

class UnknownRepoException extends RepoException {
  const UnknownRepoException([super.message = 'unknown_error']);
}

/// يترجم استثناء Postgrest/Auth الخام إلى نوع RepoException محدد.
RepoException mapSupabaseError(Object error) {
  // Never print the raw server message: it may include row values, request
  // details, or other financial context. The stable code is enough to debug.
  if (kDebugMode) {
    debugPrint(
      '[RepoError] type=${error.runtimeType}'
      '${error is PostgrestException ? ' code=${error.code ?? 'unknown'}' : ''}',
    );
  }
  if (error is PostgrestException) {
    final code = error.code;
    switch (code) {
      case '23505': // unique_violation
        return DuplicateRepoException(error.message);
      case '23503': // foreign_key_violation
      case '23514': // check_violation
      case '23502': // not_null_violation
        return ValidationRepoException(error.message);
      case '42501': // insufficient_privilege (RLS/grant denial)
        return ForbiddenRepoException(error.message);
      case 'P0001': // raised explicitly by our own RPCs (e.g. set_default_account)
        return ForbiddenRepoException(error.message);
      case '28000': // invalid_authorization_specification (our RPC's auth.uid() null check)
        return AuthRepoException(error.message);
    }
    // PostgREST returns a plain 5xx-shaped PostgrestException for backend
    // failures with no SQLSTATE code attached.
    return ServerRepoException(error.message);
  }
  if (error is AuthException) {
    return AuthRepoException(error.message);
  }
  final text = error.toString().toLowerCase();
  if (text.contains('socketexception') ||
      text.contains('timeoutexception') ||
      text.contains('failed host lookup') ||
      text.contains('connection closed') ||
      text.contains('network')) {
    return NetworkRepoException(error.toString());
  }
  return UnknownRepoException(error.toString());
}

/// رسالة عربية مناسبة للمستخدم لكل نوع خطأ — تُستخدم في نقاط الاستدعاء
/// بدل رسالة عامة واحدة لكل الحالات.
String repoExceptionMessage(RepoException e) {
  return switch (e) {
    NetworkRepoException() =>
      'تعذّر الاتصال بالخادم — تحقّق من الإنترنت وحاول مجددًا.',
    AuthRepoException() => 'الرجاء تسجيل الدخول للمتابعة.',
    ValidationRepoException() => 'بيانات غير صالحة: ${e.message}',
    ForbiddenRepoException() => 'لا تملك صلاحية تنفيذ هذه العملية.',
    DuplicateRepoException() => 'هذا العنصر موجود بالفعل.',
    NotFoundRepoException() => 'العنصر غير موجود أو تم حذفه.',
    ServerRepoException() => 'حدث خطأ في الخادم — حاول لاحقًا.',
    UnknownRepoException() => 'حدث خطأ غير متوقع — حاول مجددًا.',
  };
}
