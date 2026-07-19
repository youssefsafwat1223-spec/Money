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
  if (kDebugMode) {
    final diagnostic =
        error is PostgrestException ? _safePostgrestDiagnostic(error) : '';
    debugPrint(
      '[RepoError] type=${error.runtimeType}'
      '${error is PostgrestException ? ' code=${error.code ?? 'unknown'}' : ''}'
      '${diagnostic.isEmpty ? '' : ' message=$diagnostic'}',
    );
    debugPrintStack(
      label: '[RepoError] safe call site',
      stackTrace: StackTrace.current,
      maxFrames: 8,
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
      case '22P02': // invalid_text_representation (for example bad UUID)
      case '22023': // invalid_parameter_value from owner-checked RPCs
        return ValidationRepoException(error.message);
      case '42501': // insufficient_privilege (RLS/grant denial)
        return ForbiddenRepoException(error.message);
      case 'P0001': // raised explicitly by our own RPCs (e.g. set_default_account)
        return ForbiddenRepoException(error.message);
      case '28000': // invalid_authorization_specification (our RPC's auth.uid() null check)
        return AuthRepoException(error.message);
      case 'P0002': // no_data_found from owner-scoped RPC lookups
        return const NotFoundRepoException();
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

String _safePostgrestDiagnostic(PostgrestException error) {
  var value = error.message.trim();
  if (value.isEmpty) return '';

  // Physical-device debugging needs the response shape, while auth tokens,
  // email addresses and row identifiers must never be echoed to the console.
  value = value
      .replaceAll(
        RegExp(r'Bearer\s+[A-Za-z0-9._~-]+', caseSensitive: false),
        'Bearer <redacted>',
      )
      .replaceAll(
        RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
        '<email>',
      )
      .replaceAll(
        RegExp(
          r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b',
        ),
        '<uuid>',
      )
      .replaceAll(RegExp(r'\b[A-Za-z0-9_-]{20,}\b'), '<id>');
  return value.length <= 240 ? value : '${value.substring(0, 240)}...';
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
