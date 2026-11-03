import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/features/announcements/announcements_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets('compact messages retain expandable full content and actions: $lang', (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final preferences = NotificationPreferences(inboxState: NotificationInboxState(
        history: [
          for (var i = 0; i < 4; i++) NotificationHistoryEntry(
            id: 'synthetic-$i', kind: 'notification', title: 'Message $i',
            body: 'Complete original message body $i',
            sentAt: DateTime(2026, 10, 29 - i), route: '/settings',
          ),
        ],
      ));
      await tester.pumpWidget(ProviderScope(overrides: [
        notificationPreferencesProvider.overrideWith((ref) async => preferences),
        activeAnnouncementsProvider.overrideWith((ref) async => []),
        activeDashboardCampaignsProvider.overrideWith((ref) async => []),
      ], child: MaterialApp(
        theme: AppTheme.light, locale: Locale(lang),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: const AnnouncementsScreen(),
      )));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNWidgets(4));
      for (var i = 0; i < 4; i++) {
        expect(find.text('Message $i').hitTestable(), findsOneWidget);
      }
      expect(find.byType(QirshIllustration), findsOneWidget);
      expect(find.text('Complete original message body 0').hitTestable(), findsNothing);
      await tester.tap(find.text('Message 0'));
      await tester.pumpAndSettle();
      expect(find.text('Complete original message body 0').hitTestable(), findsOneWidget);
      final l10n = AppL10n.of(tester.element(find.byType(AnnouncementsScreen)));
      expect(find.text(l10n.annOpen).hitTestable(), findsOneWidget);
      expect(find.text(l10n.txnHide).hitTestable(), findsOneWidget);
      await tester.tap(find.text('Message 0'));
      await tester.pumpAndSettle();
      expect(find.text('Message 3').hitTestable(), findsOneWidget);
      expect(find.text(l10n.annPreferencesAction).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
