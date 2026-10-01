import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';

void main() {
  test('exact push and pull are verifiedExact by default and independently '
      'overridable; planning currency starts unknown', () {
    final defaults = ProviderContainer();
    addTearDown(defaults.dispose);
    expect(defaults.read(exactPushTransportCapabilityProvider),
        ExactTransportCapability.verifiedExact);
    expect(defaults.read(exactPullTransportCapabilityProvider),
        ExactTransportCapability.verifiedExact);
    expect(defaults.read(planningServerCurrencyCapabilityProvider),
        ExactTransportCapability.unknown);

    final pushUnsupported = ProviderContainer(
      overrides: [
        exactPushTransportCapabilityProvider.overrideWithValue(
          ExactTransportCapability.unsupported,
        ),
      ],
    );
    addTearDown(pushUnsupported.dispose);
    expect(pushUnsupported.read(exactPushTransportCapabilityProvider),
        ExactTransportCapability.unsupported);
    expect(pushUnsupported.read(exactPullTransportCapabilityProvider),
        ExactTransportCapability.verifiedExact);
  });

  test('legacy/v29 mode never parks for any push capability', () {
    for (final capability in ExactTransportCapability.values) {
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: PlanningCutoverState.legacy,
          pushCapability: capability,
        ),
        isFalse,
      );
    }
  });

  test('canonical mode parks when exact push is unverified or unsupported', () {
    for (final capability in [
      ExactTransportCapability.unknown,
      ExactTransportCapability.unsupported,
    ]) {
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: PlanningCutoverState.canonical,
          pushCapability: capability,
        ),
        isTrue,
      );
    }
    expect(exactMoneyTransportUnverifiedReason,
        'exact_money_transport_unverified');
  });

  test('canonical mode with verified exact push does not park', () {
    expect(
      shouldParkExactMoneyWrite(
        cutoverState: PlanningCutoverState.canonical,
        pushCapability: ExactTransportCapability.verifiedExact,
      ),
      isFalse,
    );
  });
}
