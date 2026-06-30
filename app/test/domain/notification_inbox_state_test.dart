import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';

void main() {
  group('NotificationInboxState', () {
    test('dismissed campaigns stay hidden in state', () {
      final state = const NotificationInboxState().markDismissed('setup');

      expect(state.hasDismissed('setup'), isTrue);
      expect(state.hasDismissed('other'), isFalse);
    });

    test('records impressions without losing sent timestamps', () {
      final sentAt = DateTime.utc(2026, 6, 30, 8);
      final state = const NotificationInboxState()
          .markMarketingSent('campaign-a', sentAt)
          .markImpression('campaign-a')
          .markImpression('campaign-a');

      expect(state.lastMarketingNotificationAt, sentAt);
      expect(state.lastSentFor('campaign-a'), sentAt);
      expect(state.impressionsFor('campaign-a'), 2);
    });

    test('round trips through notifications json', () {
      final preferences = NotificationPreferences(
        marketingMessages: false,
        inboxState: NotificationInboxState(
          firstSeenAt: DateTime.utc(2026, 6, 30),
          dismissedCampaignIds: {'trust'},
          sentJourneyIds: {'welcome'},
          impressionCounts: const {'trust': 1},
        ),
      );

      final parsed = NotificationPreferences.fromJson(preferences.toJson());

      expect(parsed.marketingMessages, isFalse);
      expect(parsed.inboxState.hasDismissed('trust'), isTrue);
      expect(parsed.inboxState.hasSentJourney('welcome'), isTrue);
      expect(parsed.inboxState.impressionsFor('trust'), 1);
    });
  });
}
