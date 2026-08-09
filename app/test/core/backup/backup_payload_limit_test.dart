// Phase-7 Batch-2 §MALI-030 §9/§11 — the v3 one-shot AEAD residual is bounded by an
// enforced PLAINTEXT cap checked BEFORE encryption: an oversized snapshot is rejected
// with a typed payloadTooLarge (never an OOM), while normal payloads encrypt/decrypt
// with unchanged semantics. No plaintext is staged to disk (pure in-memory codec).
//
// The within-cap round-trip runs a full production-cost v3 Argon2id derivation
// (64 MiB / 3 iters), so this file is tagged `crypto-prod` and runs in the canonical
// gate's SERIALIZED crypto stage (`--concurrency=1`), away from the parallel bulk
// suite whose CPU saturation trips cryptography 2.9.0's hardcoded 10s per-segment
// isolate timeout. See dart_test.yaml + tools/ci_gates.sh. TEST-ONLY.
@Tags(['crypto-prod'])
@Timeout(Duration(minutes: 3))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_crypto.dart';

void main() {
  test('an over-cap snapshot is rejected with payloadTooLarge BEFORE encryption',
      () async {
    // Tiny injected cap so the test does not allocate tens of MiB.
    final crypto = BackupCrypto(maxPlaintextBytes: 64);
    final tooBig = {
      'tables': {
        'transactions': [
          for (var i = 0; i < 50; i++) {'note': 'x' * 20},
        ],
      },
    };
    BackupEnvelopeException? thrown;
    try {
      await crypto.encryptEnvelopeV3(
        json: tooBig,
        schemaVersion: 3,
        passphrase: 'pw',
      );
    } on BackupEnvelopeException catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull);
    expect(thrown!.kind, BackupEnvelopeErrorKind.payloadTooLarge);
  });

  test('a within-cap snapshot round-trips unchanged (semantics preserved)',
      () async {
    final crypto = BackupCrypto(maxPlaintextBytes: 1024 * 1024);
    final json = {
      'schemaVersion': 3,
      'tables': {
        'transactions': [
          {'id': 't1', 'amount': 42, 'note': 'قهوة ☕'},
        ],
      },
    };
    final blob = await crypto.encryptEnvelopeV3(
      json: json,
      schemaVersion: 3,
      passphrase: 'pw',
    );
    final restored = await crypto.decryptEnvelope(
      blob: blob,
      secret: 'pw',
    );
    expect(restored['tables'], json['tables']);
  });
}
