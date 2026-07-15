import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/utils/riyadh_time.dart';

void main() {
  test('RiyadhTime keeps local calendar boundaries for local DateTimes', () {
    final local = DateTime(2026, 7, 14, 23, 30);

    expect(RiyadhTime.startOfDay(local), DateTime(2026, 7, 14));
    expect(RiyadhTime.endOfDay(local), DateTime(2026, 7, 15));
    expect(RiyadhTime.startOfMonth(local), DateTime(2026, 7));
    expect(RiyadhTime.endOfMonth(local), DateTime(2026, 8));
  });

  test('RiyadhTime activity dates and gaps use local calendar days', () {
    final first = DateTime(2026, 7, 14, 23, 55);
    final second = DateTime(2026, 7, 15, 0, 5);

    expect(RiyadhTime.activityDate(first), DateTime(2026, 7, 14));
    expect(RiyadhTime.activityDate(second), DateTime(2026, 7, 15));
    expect(RiyadhTime.dayGap(first, second), 1);
  });
}
