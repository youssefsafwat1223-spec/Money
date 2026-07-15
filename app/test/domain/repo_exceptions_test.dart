import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:postgrest/postgrest.dart';

void main() {
  group('mapSupabaseError', () {
    test('maps 23505 unique_violation to DuplicateRepoException', () {
      final e = mapSupabaseError(
        const PostgrestException(message: 'duplicate key', code: '23505'),
      );
      expect(e, isA<DuplicateRepoException>());
    });

    test('maps invalid SQL values and constraints to ValidationRepoException',
        () {
      for (final code in ['23503', '23514', '23502', '22P02', '22023']) {
        final e = mapSupabaseError(
          PostgrestException(message: 'invalid', code: code),
        );
        expect(e, isA<ValidationRepoException>(), reason: 'code $code');
      }
    });

    test('maps 42501 insufficient_privilege to ForbiddenRepoException', () {
      final e = mapSupabaseError(
        const PostgrestException(message: 'rls denied', code: '42501'),
      );
      expect(e, isA<ForbiddenRepoException>());
    });

    test('maps P0001 (our own RPC raises) to ForbiddenRepoException', () {
      final e = mapSupabaseError(
        const PostgrestException(
            message: 'account does not belong to user', code: 'P0001'),
      );
      expect(e, isA<ForbiddenRepoException>());
    });

    test('maps 28000 (RPC auth check) to AuthRepoException', () {
      final e = mapSupabaseError(
        const PostgrestException(
            message: 'authentication required', code: '28000'),
      );
      expect(e, isA<AuthRepoException>());
    });

    test('maps owner-scoped RPC no-data to NotFoundRepoException', () {
      final e = mapSupabaseError(
        const PostgrestException(message: 'not found', code: 'P0002'),
      );
      expect(e, isA<NotFoundRepoException>());
    });

    test('maps unknown PostgrestException code to ServerRepoException', () {
      final e = mapSupabaseError(
        const PostgrestException(message: 'boom', code: null),
      );
      expect(e, isA<ServerRepoException>());
    });

    test('maps network-shaped errors to NetworkRepoException', () {
      final e =
          mapSupabaseError(Exception('SocketException: Failed host lookup'));
      expect(e, isA<NetworkRepoException>());
    });

    test('maps unrecognized errors to UnknownRepoException', () {
      final e = mapSupabaseError(Exception('something else entirely'));
      expect(e, isA<UnknownRepoException>());
    });
  });

  group('repoExceptionMessage', () {
    test('returns a distinct Arabic message per exception type', () {
      final messages = {
        repoExceptionMessage(const NetworkRepoException()),
        repoExceptionMessage(const AuthRepoException()),
        repoExceptionMessage(const ValidationRepoException('x')),
        repoExceptionMessage(const ForbiddenRepoException()),
        repoExceptionMessage(const DuplicateRepoException()),
        repoExceptionMessage(const NotFoundRepoException()),
        repoExceptionMessage(const ServerRepoException()),
        repoExceptionMessage(const UnknownRepoException()),
      };
      // كل نوع يجب أن يعطي رسالة مختلفة — لا رسالة عامة واحدة تُخفي نوع الخطأ.
      expect(messages.length, 8);
    });
  });
}
