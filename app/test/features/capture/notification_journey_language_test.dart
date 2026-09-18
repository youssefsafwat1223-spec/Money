import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';
import 'package:money_companion/features/capture/services/notification_journey_service.dart';

/// JOURNEY AND CAMPAIGN NOTIFICATIONS SPEAK THE USER'S LANGUAGE.
///
/// The journey copy was already bilingual. The **remote growth campaign** half
/// was not: it read `campaign.titleAr` and `campaign.bodyAr` unconditionally,
/// in the notification and in the in-app history entry beside it. An English
/// user would have been notified in Arabic, and the record they open to see
/// what the notification said would have been Arabic too.
///
/// It was exempted from `no_arabic_only_server_copy_test` for a reason that has
/// since expired twice over: there was nowhere context-free to make the choice
/// (`core/i18n/bilingual_copy.dart` now exists), and English was unreachable
/// anyway (Settings → Language now ships). The exemption is gone.
///
/// These tests observe the persisted **history entry**, which is written from
/// the same two strings handed to `showMarketingNotification` one line above
/// it, and needs no notification plugin.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Every journey marked sent, and the marketing cooldown long expired, so the
/// campaign branch is what runs. A journey firing in the same pass would take
/// the 24-hour cooldown with it and suppress the campaign.
const _journeyIds = {
  'welcome',
  'shortcut_reminder',
  'first_transaction',
  'three_transactions',
  'first_week_summary',
};

RemoteGrowthCampaign _campaign({
  required String titleAr,
  required String titleEn,
  String? bodyAr,
  String? bodyEn,
}) =>
    RemoteGrowthCampaign(
      id: 'growth-1',
      titleAr: titleAr,
      titleEn: titleEn,
      bodyAr: bodyAr,
      bodyEn: bodyEn,
      type: 'notification',
      targetSegment: 'all',
      actionLabelAr: null,
      actionLabelEn: null,
      actionRoute: '/dashboard',
      actionUrl: null,
      validFrom: DateTime.utc(2026, 1, 1),
      validUntil: null,
      maxImpressions: null,
      cooldownHours: 0,
      isDismissible: true,
      oncePerUser: false,
      priority: 0,
      isActive: true,
      syncedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  // The service pushes the language into the notification singleton so the
  // Android channel name matches the copy. Put it back, because the singleton
  // outlives the test.
  tearDown(() => LocalNotificationService.instance.notificationLanguage = 'ar');

  Future<NotificationHistoryEntry?> sendCampaign({
    required String language,
    required RemoteGrowthCampaign campaign,
  }) async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    final settings = DriftUserSettingsRepository(db);

    // The language the user persisted — through Settings → Language, which
    // writes exactly this column.
    final current = await settings.getSettings();
    await settings.saveSettings(current.copyWith(language: language));

    final now = DateTime.utc(2026, 9, 18, 12);
    await settings.saveSettings(
      (await settings.getSettings()).copyWith(
        notificationsJson: jsonEncode(
          NotificationPreferences(
            marketingMessages: true,
            inboxState: NotificationInboxState(
              firstSeenAt: now.subtract(const Duration(days: 30)),
              lastMarketingNotificationAt:
                  now.subtract(const Duration(days: 10)),
              sentJourneyIds: _journeyIds,
            ),
          ).toJson(),
        ),
      ),
    );

    await RemoteGrowthCampaignsDao(db).replaceAll([campaign]);

    await NotificationJourneyService(
      database: db,
      loadPreferences: LoadNotificationPreferencesUseCase(settings),
      savePreferences: SaveNotificationPreferencesUseCase(settings),
      campaignsDao: RemoteGrowthCampaignsDao(db),
      now: () => now,
    ).evaluate();

    final after = await LoadNotificationPreferencesUseCase(settings).call();
    final entries = after.inboxState.history
        .where((e) => e.kind == 'campaign')
        .toList();
    return entries.isEmpty ? null : entries.first;
  }

  test('an Arabic user is notified in Arabic', () async {
    final entry = await sendCampaign(
      language: 'ar',
      campaign: _campaign(
        titleAr: 'وفّر أكثر هذا الشهر',
        titleEn: 'Save more this month',
        bodyAr: 'راجع ميزانيتك واضبط الحدود.',
        bodyEn: 'Review your budget and adjust the limits.',
      ),
    );
    expect(entry, isNotNull, reason: 'the campaign was never sent');
    expect(entry!.title, 'وفّر أكثر هذا الشهر');
    expect(entry.body, 'راجع ميزانيتك واضبط الحدود.');
  });

  test('an English user is notified in English', () async {
    final entry = await sendCampaign(
      language: 'en',
      campaign: _campaign(
        titleAr: 'وفّر أكثر هذا الشهر',
        titleEn: 'Save more this month',
        bodyAr: 'راجع ميزانيتك واضبط الحدود.',
        bodyEn: 'Review your budget and adjust the limits.',
      ),
    );
    expect(entry, isNotNull, reason: 'the campaign was never sent');
    // This is the assertion the old code failed: it read titleAr regardless.
    expect(entry!.title, 'Save more this month');
    expect(entry.body, 'Review your budget and adjust the limits.');
  });

  test('an untranslated campaign still reaches an English user, in Arabic',
      () async {
    // Operator-authored rows can lag. A notification that says nothing is
    // worse than one in the wrong language.
    final entry = await sendCampaign(
      language: 'en',
      campaign: _campaign(
        titleAr: 'وفّر أكثر هذا الشهر',
        titleEn: '',
        bodyAr: 'راجع ميزانيتك.',
        bodyEn: null,
      ),
    );
    expect(entry, isNotNull);
    expect(entry!.title, 'وفّر أكثر هذا الشهر');
    expect(entry.body, 'راجع ميزانيتك.');
  });

  test('a campaign with no body falls back to its own title, in language',
      () async {
    final entry = await sendCampaign(
      language: 'en',
      campaign: _campaign(
        titleAr: 'وفّر أكثر',
        titleEn: 'Save more',
      ),
    );
    expect(entry, isNotNull);
    expect(entry!.title, 'Save more');
    expect(entry.body, 'Save more',
        reason: 'the body fallback must follow the same language as the title');
  });

  test('the notification channel language follows the same persisted value',
      () async {
    // `_channel` and the Android channel name read
    // `LocalNotificationService.notificationLanguage`. Left to a widget-tree
    // provider it can lag `evaluateAfterCapture`, which would put English copy
    // inside a channel named «رسائل ونصائح قرش».
    LocalNotificationService.instance.notificationLanguage = 'ar';
    await sendCampaign(
      language: 'en',
      campaign: _campaign(titleAr: 'عرض', titleEn: 'Offer'),
    );
    expect(LocalNotificationService.instance.notificationLanguage, 'en');
  });
}
