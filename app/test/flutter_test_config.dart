import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';

import 'harness/egress_test_support.dart';

/// Every test file starts with an in-memory, RESOLVED egress gate holding a
/// durable ON record for 'uid-a' (Astra H2.2: an absent record is NOT ON), so no test touches the platform channels of the
/// durable store. Tests that exercise the gate install their own.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    CloudEgressGate.instance = TestEgress(seedOn: true).gate;
    ConsentAuthority.egressFrozen = false;
  });
  await testMain();
}
