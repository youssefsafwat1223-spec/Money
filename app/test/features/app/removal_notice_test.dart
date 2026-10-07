import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/app.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/l10n/app_localizations.dart';

Widget _app(String locale, {required Widget Function() home}) => MaterialApp(
      locale: Locale(locale),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) =>
          Stack(children: [child!, const RemovalNoticeHost()]),
      home: Scaffold(body: home()),
    );

void main() {
  final pending = AppSession.instance.removalNoticePending;
  setUp(() => pending.value = false);
  tearDown(() => pending.value = false);

  testWidgets('a notice set BEFORE the next screen mounts (the scope swap) is '
      'shown once on it, then consumed (EN)', (tester) async {
    pending.value = true; // set while the old UI is being disposed
    await tester.pumpWidget(_app('en', home: () => const SizedBox()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Data removed from this device'), findsOneWidget);
    expect(pending.value, isFalse);
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(find.text('Data removed from this device'), findsNothing);

    // A second screen/rebuild shows nothing.
    await tester.pumpWidget(_app('en', home: () => const Text('next')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Data removed from this device'), findsNothing);
  });

  testWidgets('a notice set while the host is already mounted is shown (AR)',
      (tester) async {
    await tester.pumpWidget(_app('ar', home: () => const SizedBox()));
    await tester.pump();
    expect(find.text('تم حذف البيانات من هذا الجهاز'), findsNothing);
    pending.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('تم حذف البيانات من هذا الجهاز'), findsOneWidget);
  });

  testWidgets('no notice when nothing was removed', (tester) async {
    await tester.pumpWidget(_app('en', home: () => const SizedBox()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Data removed from this device'), findsNothing);
  });
}
