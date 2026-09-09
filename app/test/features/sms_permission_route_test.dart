import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression for the /capture/sms-permission route rendering an ErrorWidget.
///
/// Found by the exhaustive control sweep, which opens every static route:
/// arriving at the route produced ErrorWidget immediately. SmsPermissionScreen
/// is a SHEET body — Directionality > ClipRRect > MaliGlass(sheet) > Column,
/// with no Scaffold and no bounded height — and its own showSheet() supplies
/// navySheetTheme + FractionallySizedBox inside showModalBottomSheet. The route
/// built it bare, so the Column had no bounded parent.
///
/// Structural rather than a widget pump: building the real screen needs the
/// full app theme and providers, and the defect is precisely that the route
/// omitted the ancestors the screen declares it requires.
void main() {
  final router =
      File('lib/core/router/app_router.dart').readAsStringSync();

  String routeBlock(String path) {
    final at = router.indexOf("path: '$path'");
    expect(at, isNonNegative, reason: 'route $path missing');
    final end = router.indexOf('GoRoute(', at);
    return router.substring(at, end > at ? end : router.length);
  }

  test('the sheet-body route supplies the ancestors the screen requires', () {
    final block = routeBlock('/capture/sms-permission');
    expect(block.contains('SmsPermissionScreen()'), isTrue);
    expect(block.contains('Scaffold('), isTrue,
        reason: 'a sheet body rendered as a page needs a Scaffold ancestor');
    expect(block.contains('navySheetTheme('), isTrue,
        reason: 'showSheet() wraps it in navySheetTheme; the route must match');
    expect(block.contains('FractionallySizedBox'), isTrue,
        reason: 'the Column is unbounded without a height-constraining parent');
  });

  test('the screen still declares showSheet as its sheet presentation', () {
    // If this stops being a sheet body, the route wrapper above is wrong and
    // should be revisited rather than left as cargo.
    final screen =
        File('lib/features/capture/sms_permission_screen.dart').readAsStringSync();
    expect(screen.contains('static Future<void> showSheet('), isTrue);
    expect(screen.contains('showModalBottomSheet<void>('), isTrue);
    expect(screen.contains('MaliGlassVariant.sheet'), isTrue,
        reason: 'sheet variant is why it has no Scaffold of its own');
  });
}
