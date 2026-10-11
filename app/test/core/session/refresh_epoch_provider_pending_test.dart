import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';

import '../../harness/egress_test_support.dart';
import 'f2_fixture.dart';
import 'refresh_epoch_test.dart' show refreshEpochCase;

void main() {
  refreshEpochCase('same UID reauthentication', refreshDuringProvider: true);
  refreshEpochCase('same UID reauthentication',
      failure: true, refreshDuringProvider: true);

  for (final invalidation in ['expired capability', 'removal']) {
    test('rejected $invalidation acceptance does not advance egress epoch',
        () async {
      final egress = TestEgress().install();
      final f = await F2Fixture.create();
      try {
        await f.signIn('uid-a');
        final attempt = f.session.beginAuthAttempt();
        if (invalidation == 'removal') {
          await f.session.removeDataFromDevice();
        }
        final epoch = egress.gate.epoch;
        final from = f.storage.attempts.length;
        await expectLater(
            f.session.setIdentity(
                method: 'google',
                userId: 'uid-a',
                attempt: attempt,
                sessionCurrent: () => invalidation != 'expired capability'),
            throwsA(isA<StaleAdmissionException>()));
        expect(egress.gate.epoch, epoch);
        expect(f.storage.attempts.skip(from), isEmpty);
      } finally {
        await f.dispose();
      }
    });
  }
}
