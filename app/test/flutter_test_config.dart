import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';

import 'harness/egress_test_support.dart';

/// Every test file starts with an in-memory egress gate (no record = nothing
/// denied at the service level), so no test touches the platform channels of the
/// durable store. Tests that exercise the gate install their own.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    CloudEgressGate.instance = TestEgress().gate;
    ConsentAuthority.egressFrozen = false;
  });
  await testMain();
}
