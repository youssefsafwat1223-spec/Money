// Offline visual QA only. Imported by tool/visual_parity/main.dart, never lib/.
// Catalog and plan fixtures are written solely into its in-memory database.
// No authentication, consent, entitlement or production feature flag is changed.
import 'dart:async';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

const visualParitySecondaryFixtureIds = <String, String>{
  'activePlan': 'p-plan-active',
  'closedPlan': 'p-plan-closed',
  'upcomingPlan': 'p-plan-upcoming',
  'talabatMerchant': 'p-merchant-talabat',
  'carrefourMerchant': 'p-merchant-carrefour',
  'breadfastMerchant': 'p-merchant-breadfast',
  'talabatCoupon': 'p-coupon-talabat',
  'carrefourCoupon': 'p-coupon-carrefour',
  'breadfastCoupon': 'p-coupon-breadfast',
};

/// Referrals are intentionally NOT populated: the production protocol is
/// retired for Beta 1. Keep its unavailable state rather than inventing active
/// entitlement or overriding the retirement gate to resemble the HTML demo.
const visualParitySecondaryDeviations = <String, String>{
  'referrals': 'Retired Beta 1 protocol; actual unavailable UI is preserved.',
  'forYouOffers':
      'No synthetic personalization consent; personalized section stays absent.',
  'couponExternalLinks': 'Demo offers are code-only and have no external URLs.',
  'messages':
      'Bilingual local catalog notices; no push or OS notification is sent.',
  'plans':
      'Spending is calculated by the actual repository from synthetic ledger rows.',
};

void _requireOfflineDebug() {
  if (kReleaseMode || SupabaseConfig.isConfigured) {
    throw StateError('secondary_visual_fixtures_require_offline_debug');
  }
}

Future<void> _requireMemory(AppDatabase db) async {
  _requireOfflineDebug();
  final rows = await db.customSelect('PRAGMA database_list').get();
  if (!rows.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('secondary_visual_fixtures_require_memory_database');
  }
}

Future<T> _outcome<T>(String mode) => mode == 'loading'
    ? Completer<T>().future
    : Future<T>.error(StateError('visual_fixture_error'));

/// Add to the root fixture's ProviderContainer overrides. Capability visibility
/// is scoped only to this disposable UI fixture; affiliate tracking remains OFF
/// and merchant personalization is never opted in. Catalog data still passes
/// through the production eligibility/ranking providers and actual local DAOs.
List<Override> visualParitySecondaryOverrides({required String mode}) {
  _requireOfflineDebug();
  return [
    couponsEnabledProvider.overrideWithValue(true),
    merchantOffersEnabledProvider.overrideWithValue(true),
    affiliateTrackingEnabledProvider.overrideWithValue(false),
    merchantPersonalizationEnabledProvider.overrideWith((ref) async => false),
    if (mode == 'loading' || mode == 'error') ...[
      plansWithSpentProvider
          .overrideWith((ref) => _outcome<List<PlanProgress>>(mode)),
      cachedCouponsProvider
          .overrideWith((ref) => _outcome<List<CouponOffer>>(mode)),
      notificationPreferencesProvider
          .overrideWith((ref) => _outcome<NotificationPreferences>(mode)),
    ],
  ];
}

/// Call after the base demo ledger/accounts are seeded and before mounting the
/// UI. The database identity must be the same one supplied to the ProviderScope.
/// Repeated calls update the same plan IDs and replace only synthetic catalogs.
Future<void> seedVisualParitySecondaryFixtures(
  ProviderContainer container,
  AppDatabase db, {
  DateTime? fixtureNow,
}) async {
  await _requireMemory(db);
  if (!identical(container.read(appDatabaseProvider), db)) {
    throw StateError('secondary_visual_fixture_database_mismatch');
  }
  final now = fixtureNow ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final accounts = await container.read(accountRepositoryProvider).getAll();
  final egpAccounts = accounts.where((a) => a.currency == 'EGP').toList();
  // No real or hidden default account is invented when the base fixture is
  // empty. Plans are seeded only after a compatible synthetic account exists.
  if (egpAccounts.isNotEmpty) {
    final accountId = egpAccounts.first.id;
    final plans = container.read(planRepositoryProvider);
    for (final plan in [
      PlanEntity(
        id: 'p-plan-active',
        name: 'رحلة دهب · Dahab weekend',
        budgetAmountMoney: Money(900000, 'EGP'),
        currency: 'EGP',
        startDate: day.subtract(const Duration(days: 7)),
        endDate: day.add(const Duration(days: 14)),
        accountIds: [accountId],
        cardLast4s: const [],
        status: PlanStatus.active,
        createdAt: day.subtract(const Duration(days: 10)),
        icon: 'plane',
      ),
      PlanEntity(
        id: 'p-plan-closed',
        name: 'تجهيز البيت · Home essentials',
        budgetAmountMoney: Money(600000, 'EGP'),
        currency: 'EGP',
        startDate: day.subtract(const Duration(days: 65)),
        endDate: day.subtract(const Duration(days: 40)),
        accountIds: [accountId],
        cardLast4s: const [],
        status: PlanStatus.closed,
        createdAt: day.subtract(const Duration(days: 70)),
        icon: 'house',
      ),
      PlanEntity(
        id: 'p-plan-upcoming',
        name: 'عزومة رمضان · Ramadan gathering',
        budgetAmountMoney: Money(600000, 'EGP'),
        currency: 'EGP',
        startDate: day.add(const Duration(days: 110)),
        endDate: day.add(const Duration(days: 140)),
        accountIds: [accountId],
        cardLast4s: const [],
        status: PlanStatus.active,
        createdAt: day,
        icon: 'utensils-crossed',
      ),
    ]) {
      await plans.save(plan);
    }
  }

  // Exercise the existing conditional Smart Inbox UI using only this guarded
  // in-memory fixture. These records never enter the user's database.
  final inbox = DriftSmartInboxRepository(db);
  for (var index = 0; index < 3; index++) {
    await inbox.saveUnprocessableCapture(
      payloadId: 'visual-unsupported-$index',
      rawMessage: 'Synthetic bank SMS for visual QA: payment details require review.',
      source: 'visual_fixture', receivedAt: now.subtract(Duration(minutes: index + 1)),
      lang: 'en');
  }

  await RemoteCatalogMerchantsDao(db).upsertAll(const [
    RemoteCatalogMerchant(
        id: 'p-merchant-talabat',
        slug: 'preview-talabat',
        nameAr: 'طلبات',
        nameEn: 'Talabat',
        countryCodes: ['EG'],
        isActive: true,
        isDeleted: false,
        updatedVersion: 1),
    RemoteCatalogMerchant(
        id: 'p-merchant-carrefour',
        slug: 'preview-carrefour',
        nameAr: 'كارفور',
        nameEn: 'Carrefour',
        countryCodes: ['EG'],
        isActive: true,
        isDeleted: false,
        updatedVersion: 1),
    RemoteCatalogMerchant(
        id: 'p-merchant-breadfast',
        slug: 'preview-breadfast',
        nameAr: 'بريدفاست',
        nameEn: 'Breadfast',
        countryCodes: ['EG'],
        isActive: true,
        isDeleted: false,
        updatedVersion: 1),
  ]);
  await RemoteCouponsDao(db).replaceAll(_offers());
  await RemoteAnnouncementsDao(db).replaceAll(_messages(now.toUtc()));
}

List<CouponOffer> _offers() {
  final from = DateTime.utc(2020);
  final until = DateTime.utc(2040);
  return [
    CouponOffer(
      id: 'p-coupon-talabat',
      slug: 'preview-talabat',
      partnerName: 'Talabat',
      titleAr: 'خصم ٢٠٪ على طلبك',
      titleEn: '20% off your order',
      descriptionAr: 'عرض تجريبي غير حقيقي لاختبار الواجهة فقط.',
      descriptionEn: 'Not a real offer. Synthetic visual QA content only.',
      redemptionType: CouponRedemptionType.code,
      code: 'DEMO20',
      category: const CouponCategory(
          key: 'dining', labelAr: 'مطاعم وتوصيل', labelEn: 'Dining & delivery'),
      validFrom: from,
      validUntil: until,
      countryCodes: const ['EG'],
      merchantId: 'p-merchant-talabat',
      merchantNameAr: 'طلبات',
      merchantNameEn: 'Talabat',
      featured: true,
      priority: 30,
      accentHex: '#F25C05',
      spendHintCategoryKeys: const ['restaurants'],
      benefitType: 'percent',
      discountBps: 2000,
      minSpendMinor: 10000,
      maxSavingMinor: 26000,
      benefitCurrency: 'EGP',
      source: 'visual_fixture',
      tags: const [
        CouponTag(key: 'preview', labelAr: 'تجريبي', labelEn: 'Demo')
      ],
    ),
    CouponOffer(
      id: 'p-coupon-carrefour',
      slug: 'preview-carrefour',
      partnerName: 'Carrefour',
      titleAr: 'خصم ٥٪ على البقالة',
      titleEn: '5% off groceries',
      descriptionAr: 'عرض تجريبي غير حقيقي لاختبار الواجهة فقط.',
      descriptionEn: 'Not a real offer. Synthetic visual QA content only.',
      redemptionType: CouponRedemptionType.code,
      code: 'DEMO5',
      category: const CouponCategory(
          key: 'groceries', labelAr: 'بقالة', labelEn: 'Groceries'),
      validFrom: from,
      validUntil: until,
      countryCodes: const ['EG'],
      merchantId: 'p-merchant-carrefour',
      merchantNameAr: 'كارفور',
      merchantNameEn: 'Carrefour',
      priority: 20,
      accentHex: '#0E4C92',
      spendHintCategoryKeys: const ['groceries'],
      benefitType: 'percent',
      discountBps: 500,
      benefitCurrency: 'EGP',
      source: 'visual_fixture',
    ),
    CouponOffer(
      id: 'p-coupon-breadfast',
      slug: 'preview-breadfast',
      partnerName: 'Breadfast',
      titleAr: 'توصيل مجاني فوق ٤٠٠ ج.م',
      titleEn: 'Free delivery over EGP 400',
      descriptionAr: 'عرض تجريبي غير حقيقي؛ لا يتم اختراع قيمة مالية للتوصيل.',
      descriptionEn:
          'Not a real offer. Shipping has no invented savings amount.',
      redemptionType: CouponRedemptionType.code,
      code: 'DEMODEL',
      category: const CouponCategory(
          key: 'groceries', labelAr: 'بقالة', labelEn: 'Groceries'),
      validFrom: from,
      validUntil: until,
      countryCodes: const ['EG'],
      merchantId: 'p-merchant-breadfast',
      merchantNameAr: 'بريدفاست',
      merchantNameEn: 'Breadfast',
      priority: 10,
      accentHex: '#E5484D',
      benefitType: 'free_shipping',
      minSpendMinor: 40000,
      benefitCurrency: 'EGP',
      source: 'visual_fixture',
    ),
    // Negative fixtures prove that production eligibility remains in use.
    CouponOffer(
      id: 'p-coupon-expired',
      slug: 'preview-expired',
      partnerName: 'Preview',
      titleAr: 'عرض منتهي لا يجب عرضه',
      titleEn: 'Expired offer must stay hidden',
      descriptionAr: 'تجريبي',
      descriptionEn: 'Synthetic negative fixture',
      redemptionType: CouponRedemptionType.code,
      code: 'EXPIRED',
      category: const CouponCategory(
          key: 'dining', labelAr: 'مطاعم', labelEn: 'Dining'),
      validFrom: from,
      validUntil: DateTime.utc(2021),
    ),
    CouponOffer(
      id: 'p-coupon-country',
      slug: 'preview-other-country',
      partnerName: 'Preview',
      titleAr: 'عرض لدولة أخرى لا يجب عرضه',
      titleEn: 'Other-country offer must stay hidden',
      descriptionAr: 'تجريبي',
      descriptionEn: 'Synthetic negative fixture',
      redemptionType: CouponRedemptionType.code,
      code: 'OTHERCOUNTRY',
      category: const CouponCategory(
          key: 'dining', labelAr: 'مطاعم', labelEn: 'Dining'),
      validFrom: from,
      validUntil: until,
      countryCodes: const ['AE'],
    ),
  ];
}

List<RemoteAnnouncement> _messages(DateTime now) => [
      for (final spec in <(String, String, String, String, String, String)>[
        (
          'budget',
          'تجاوزت ميزانية البقالة',
          'Groceries budget exceeded',
          'رسالة تجريبية: راجع مصروفات البقالة لهذا الشهر.',
          'Synthetic message: review groceries spending this month.',
          'warning'
        ),
        (
          'bill',
          'اشتراك Netflix يتجدد قريبًا',
          'Netflix renews soon',
          'رسالة تجريبية لتجربة فتح الاشتراكات.',
          'Synthetic message for opening subscriptions.',
          'info'
        ),
        (
          'goal',
          'وصلت إلى ٦٢٪ من هدف الادخار',
          'You reached 62% of the savings goal',
          'رسالة تجريبية وليست نتيجة محسوبة من بياناتك.',
          'Synthetic message, not a calculation from your financial data.',
          'info'
        ),
        (
          'report',
          'تقريرك الأسبوعي جاهز',
          'Your weekly report is ready',
          'رسالة تجريبية لفتح التحليلات.',
          'Synthetic message for opening Insights.',
          'info'
        ),
      ].indexed)
        RemoteAnnouncement(
          id: 'p-message-${spec.$2.$1}',
          titleAr: spec.$2.$2,
          titleEn: spec.$2.$3,
          bodyAr: spec.$2.$4,
          bodyEn: spec.$2.$5,
          severity: spec.$2.$6,
          minAppVersion: null,
          maxAppVersion: null,
          actionLabelAr: 'فتح',
          actionLabelEn: 'Open',
          actionUrl: switch (spec.$2.$1) {
            'budget' => '/budgets',
            'bill' => '/subscriptions',
            'goal' => '/goals',
            _ => '/reports',
          },
          validFrom: now.subtract(Duration(days: spec.$1 + 1)),
          validUntil: null,
          isDismissible: true,
          priority: 4 - spec.$1,
          isDismissed: false,
          dismissedAt: null,
          syncedAt: now,
        ),
    ];
