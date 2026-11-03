import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/account_deletion_service.dart';
import 'package:money_companion/features/settings/consent_status.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _BeforeRpcCancellation implements AccountDeletionService {
  final scheduled = DateTime.utc(2026, 12, 3);
  var cancels = 0;
  var requests = 0;
  @override
  Future<AccountDeletionStatus> getStatus() async =>
      AccountDeletionStatus(scheduledAt: scheduled);
  @override
  Future<void> cancelDeletion() async {
    cancels++;
    throw StateError('private_synthetic_no_rpc');
  }

  @override
  Future<DateTime?> requestDeletion() async {
    requests++;
    throw StateError('request_forbidden');
  }
}

double contrast(Color a, Color b) {
  final l1 = a.computeLuminance(), l2 = b.computeLuminance();
  return ((l1 > l2 ? l1 : l2) + .05) / ((l1 < l2 ? l1 : l2) + .05);
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets(
          'actual PendingDeletionCard cancel legibility and rejected callback $lang dark$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final service = _BeforeRpcCancellation();
        final unloadedSettings = Completer<UserSettingsEntity>();
        await tester.pumpWidget(ProviderScope(
            overrides: [
              accountDeletionServiceProvider.overrideWithValue(service),
              accountDeletionStatusProvider
                  .overrideWith((ref) => service.getStatus()),
              // This test concerns the actual public pending card only. An uncompleted
              // settings load does not grant consent or access any database/service.
              userSettingsProvider
                  .overrideWith((ref) => unloadedSettings.future),
            ],
            child: MaterialApp(
                theme: dark ? AppTheme.dark : AppTheme.light,
                locale: Locale(lang),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: const PrivacyScreen())));
        await tester.pumpAndSettle();
        final l = lookupAppL10n(Locale(lang));
        final cancel = find.widgetWithText(TextButton, l.privCancelDeletion);
        await tester.scrollUntilVisible(cancel, 180, maxScrolls: 20);
        await tester.pumpAndSettle();
        final paragraphFinder =
            find.descendant(of: cancel, matching: find.byType(RichText));
        final paragraph = tester.renderObject<RenderParagraph>(paragraphFinder);
        final foreground = paragraph.text.style!.color!;
        final colors = dark ? AppColors.dark : AppColors.light;
        final background =
            Color.alphaBlend(colors.danger.withValues(alpha: .08), colors.bg);
        final ratio = contrast(foreground, background);
        debugPrint(
            'ACTUAL_CANCEL_COLOR lang=$lang dark=$dark fg=${foreground.toARGB32().toRadixString(16)} bg=${background.toARGB32().toRadixString(16)} contrast=$ratio');
        final cancelWidget = tester.widget<TextButton>(cancel);
        final originalCallback = cancelWidget.onPressed;
        expect(
            cancelWidget.style?.foregroundColor
                ?.resolve({WidgetState.disabled}),
            isNull,
            reason:
                'local enabled-color override must leave disabled foreground to the SDK/theme');
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        await tester
            .tap(find.widgetWithText(TextButton, l.privCancelDeletion).last);
        await tester.pumpAndSettle();
        final failed = find.text(l.privCancelFailed).evaluate().isNotEmpty;
        final privateVisible =
            find.textContaining('private_synthetic').evaluate().isNotEmpty;
        final scheduledVisible =
            find.textContaining('2026-12-03').evaluate().isNotEmpty ||
                find.textContaining('03-12-2026').evaluate().isNotEmpty;
        final calls = service.cancels;
        final requests = service.requests;
        final error = tester.takeException();
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(error, isNull);
        expect(originalCallback, isNotNull);
        expect(calls, 1);
        expect(requests, 0);
        expect(failed, isTrue);
        expect(privateVisible, isFalse);
        expect(scheduledVisible, isTrue);
        expect(ratio, greaterThanOrEqualTo(4.5));
      });
    }
  }
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets(
          'actual unknown consent action legibility and read-only refresh $lang dark$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var settingsReads = 0, factsReads = 0;
        final settings = UserSettingsEntity(
            id: 'presentation-only',
            country: 'EG',
            currency: 'EGP',
            language: lang,
            theme: dark ? 'dark' : 'light',
            inputMethod: 'manual',
            notificationsJson: '{}',
            privacyModeEnabled: false,
            // A legacy AI-only stored choice is not a live consent capability.
            // Unreadable facts select the same actual unknown-status controls.
            cloudConsentState: ConsentState.declined,
            aiConsentState: ConsentState.accepted);
        final service = _BeforeRpcCancellation();
        await tester.pumpWidget(ProviderScope(
            overrides: [
              userSettingsProvider.overrideWith((ref) async {
                settingsReads++;
                return settings;
              }),
              consentLiveFactsProvider.overrideWith((ref) async {
                factsReads++;
                return ConsentLiveFacts.unreadable;
              }),
              accountDeletionStatusProvider
                  .overrideWith((ref) => service.getStatus()),
              accountDeletionServiceProvider.overrideWithValue(service),
              merchantOffersEnabledProvider.overrideWithValue(false),
            ],
            child: MaterialApp(
                theme: dark ? AppTheme.dark : AppTheme.light,
                locale: Locale(lang),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: const PrivacyScreen())));
        await tester.pumpAndSettle();
        final colors = dark ? AppColors.dark : AppColors.light;
        final ratios = <double>[];
        for (final key in ['consentTurnOff', 'consentRefresh']) {
          final action = find.byKey(Key(key));
          await tester.scrollUntilVisible(action, 180, maxScrolls: 20);
          await tester.pumpAndSettle();
          final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: action, matching: find.byType(RichText)));
          final foreground = paragraph.text.style!.color!;
          final ratio = contrast(foreground, colors.surface);
          ratios.add(ratio);
          debugPrint(
              'ACTUAL_UNKNOWN_COLOR key=$key lang=$lang dark=$dark fg=${foreground.toARGB32().toRadixString(16)} bg=${colors.surface.toARGB32().toRadixString(16)} contrast=$ratio');
          final actionWidget = tester.widget<ButtonStyleButton>(action);
          expect(actionWidget.onPressed, isNotNull);
          expect(
              actionWidget.style?.foregroundColor
                  ?.resolve({WidgetState.disabled}),
              isNull,
              reason:
                  'local enabled-color override must leave disabled foreground to the SDK/theme');
        }
        expect(find.byKey(const Key('consentTurnOn')), findsNothing);
        final beforeSettings = settingsReads, beforeFacts = factsReads;
        await tester.tap(find.byKey(const Key('consentRefresh')));
        await tester.pumpAndSettle();
        expect(settingsReads, beforeSettings + 1);
        expect(factsReads, beforeFacts + 1);
        expect(service.cancels, 0);
        expect(service.requests, 0);
        expect(settings.cloudConsentState, ConsentState.declined);
        expect(settings.aiConsentState, ConsentState.accepted);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        for (final ratio in ratios) {
          expect(ratio, greaterThanOrEqualTo(4.5));
        }
      });
    }
  }
}
