import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/security/app_lock_gate.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// A cancelled or failed Face ID prompt leaves the gate locked. Going to the
/// background and coming back within the 30 s grace used to open it with no
/// authentication at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const authChannel = MethodChannel('plugins.flutter.io/local_auth');

  Future<List<bool>> pumpGate(WidgetTester tester, List<bool> answers) async {
    FlutterSecureStorage.setMockInitialValues({'app_lock_enabled': '1'});
    final asked = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      authChannel,
      (call) async {
        if (call.method != 'authenticate') return null;
        final ok =
            asked.length < answers.length ? answers[asked.length] : false;
        asked.add(ok);
        return ok;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(authChannel, null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AppTheme.light,
        home: const AppLockGate(child: Scaffold(body: Text('PROTECTED'))),
      ),
    );
    await tester.pumpAndSettle();
    return asked;
  }

  Future<void> quickBackgroundTrip(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  testWidgets('a quick background trip does not open a locked gate',
      (tester) async {
    final asked = await pumpGate(tester, [false, false]);
    expect(find.text('PROTECTED'), findsNothing);

    await quickBackgroundTrip(tester);

    expect(find.text('PROTECTED'), findsNothing);
    expect(asked, [false, false], reason: 'returning asks for Face ID again');
  });

  testWidgets('it opens only once authentication succeeds', (tester) async {
    await pumpGate(tester, [false, true]);
    expect(find.text('PROTECTED'), findsNothing);

    await quickBackgroundTrip(tester);

    expect(find.text('PROTECTED'), findsOneWidget);
  });

  testWidgets('an unlocked app stays open after a quick background trip',
      (tester) async {
    final asked = await pumpGate(tester, [true]);
    expect(find.text('PROTECTED'), findsOneWidget);
    final before = asked.length;

    await quickBackgroundTrip(tester);

    expect(find.text('PROTECTED'), findsOneWidget);
    expect(asked.length, before,
        reason: 'inside the 30 s grace, no new prompt');
  });
}
