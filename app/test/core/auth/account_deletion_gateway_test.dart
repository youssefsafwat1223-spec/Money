import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/account_deletion_gateway.dart';
import 'package:money_companion/core/auth/account_deletion_service.dart';

class _Service implements AccountDeletionService {
  _Service({this.result, this.error});
  final DateTime? result;
  final Object? error;
  int calls = 0;

  @override
  Future<DateTime?> requestDeletion() async {
    calls++;
    if (error != null) throw error!;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('scheduled gateway reports the schedule as accepted, never completed',
      () async {
    final when = DateTime.utc(2026, 11, 14);
    final service = _Service(result: when);
    final states = await ScheduledAccountDeletionGateway(service).delete().toList();
    expect(service.calls, 1);
    expect(states.whereType<AccountDeletionCompleted>(), isEmpty,
        reason: 'a 30-day schedule is not a completed deletion');
    expect(states.first, isA<AccountDeletionInProgress>());
    final last = states.last;
    expect(last, isA<AccountDeletionAccepted>());
    expect((last as AccountDeletionAccepted).scheduledFor, when);
  });

  test('a request error is a retryable failure', () async {
    final states = await ScheduledAccountDeletionGateway(
            _Service(error: Exception('offline')))
        .delete()
        .toList();
    expect(states.last, isA<AccountDeletionFailed>());
    expect((states.last as AccountDeletionFailed).retryable, isTrue);
    expect(states.whereType<AccountDeletionCompleted>(), isEmpty);
    expect(states.whereType<AccountDeletionAccepted>(), isEmpty);
  });

  test('nothing to schedule against (no backend) is a non-retryable failure',
      () async {
    final states =
        await ScheduledAccountDeletionGateway(_Service(result: null)).delete().toList();
    expect(states.last, isA<AccountDeletionFailed>());
    expect((states.last as AccountDeletionFailed).retryable, isFalse);
    expect(states.whereType<AccountDeletionCompleted>(), isEmpty);
  });

  test('the scheduled gateway does not claim immediate deletion', () {
    expect(ScheduledAccountDeletionGateway(_Service()).deletesImmediately,
        isFalse);
  });
}
