import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/security/app_lock_gate.dart';
import 'package:money_companion/core/security/lock_prompt_language.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// THE DEFECT THIS FILE HOLDS SHUT.
///
/// `AppLockGate` raises the OS prompt from a post-frame callback on the FIRST
/// frame — by design, so protected financial UI is never on screen
/// unauthenticated. At that instant the encrypted database has not been opened,
/// so the app is still rendering in its default language whatever the user
/// persisted. The gate used to compose the prompt from `context.l10n`, so on a
/// cold start with English persisted, iOS was handed the Arabic string and drew
/// it. Measured on a real device, same install, process restart:
///
///   persisted=en resolved=en promptSeen=true promptAr=true promptEn=false
///
/// Each test below pins the ambient locale to Arabic — the app default, which
/// is exactly what `context.l10n` returns at that moment — and sets the mirror
/// to the language the user actually persisted. Against the old gate the first
/// test fails: the prompt comes back Arabic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const authChannel = MethodChannel('plugins.flutter.io/local_auth');

  /// The reason string handed to the platform, or null if the gate never asked.
  ///
  /// [persisted] is the mirrored language; [ambient] is the locale the app is
  /// rendering in when the gate fires, which on a cold start is the default
  /// rather than the reader's.
  Future<String?> promptFor(
    WidgetTester tester, {
    required String persisted,
    required String ambient,
  }) async {
    FlutterSecureStorage.setMockInitialValues({'app_lock_enabled': '1'});
    await LockPromptLanguage.set(persisted);

    String? reason;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      authChannel,
      (call) async {
        if (call.method == 'authenticate') {
          reason ??= (call.arguments as Map)['localizedReason'] as String?;
        }
        // Denied: the gate must stay locked, which is also what keeps this test
        // from asserting anything about unlocking.
        return false;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(authChannel, null));

    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(ambient),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AppTheme.light,
        home: const AppLockGate(
          child: Scaffold(body: Text('PROTECTED')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return reason;
  }

  testWidgets('English persisted, app still in its default: prompt is English',
      (tester) async {
    final reason =
        await promptFor(tester, persisted: 'en', ambient: 'ar');
    final en = await AppL10n.delegate.load(const Locale('en'));
    final ar = await AppL10n.delegate.load(const Locale('ar'));
    expect(reason, isNotNull,
        reason: 'the gate never asked the platform to authenticate');
    expect(reason, en.lockPrompt);
    expect(reason, isNot(ar.lockPrompt));
  });

  testWidgets('Arabic persisted: prompt is Arabic', (tester) async {
    final reason =
        await promptFor(tester, persisted: 'ar', ambient: 'ar');
    final ar = await AppL10n.delegate.load(const Locale('ar'));
    expect(reason, ar.lockPrompt);
  });

  testWidgets('the mirror wins over the ambient locale in both directions',
      (tester) async {
    // The mirror is the source of truth, not a fallback for when the locale is
    // missing. An English app whose mirror says Arabic prompts in Arabic — the
    // case a reinstall can produce, recorded rather than hidden.
    final reason =
        await promptFor(tester, persisted: 'ar', ambient: 'en');
    final ar = await AppL10n.delegate.load(const Locale('ar'));
    expect(reason, ar.lockPrompt);
  });

  testWidgets('a denied prompt leaves the protected child off screen',
      (tester) async {
    // The language work must not touch what the gate is for. The platform said
    // no above; the child must not be built.
    await promptFor(tester, persisted: 'en', ambient: 'ar');
    expect(find.text('PROTECTED'), findsNothing);
  });
}
