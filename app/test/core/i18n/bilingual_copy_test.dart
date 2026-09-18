import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/i18n/bilingual_copy.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';

/// One rule, in one place, for every surface that reads a server-authored row.
///
/// It used to live at each call site, and four surfaces chose independently —
/// one of them wrong in three fields at once. The rule is now context-free so
/// notifications can use the same one the banners do.
RemoteGrowthCampaign _campaign({
  required String titleAr,
  required String titleEn,
  String? bodyAr,
  String? bodyEn,
}) =>
    RemoteGrowthCampaign(
      id: 'c1',
      titleAr: titleAr,
      titleEn: titleEn,
      bodyAr: bodyAr,
      bodyEn: bodyEn,
      type: 'notification',
      targetSegment: 'all',
      actionLabelAr: null,
      actionLabelEn: null,
      actionRoute: null,
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
  test('Arabic takes the Arabic field', () {
    final c = _campaign(
        titleAr: 'عرض', titleEn: 'Offer', bodyAr: 'نص', bodyEn: 'Body');
    expect(c.titleIn('ar'), 'عرض');
    expect(c.bodyIn('ar'), 'نص');
  });

  test('English takes the English field', () {
    final c = _campaign(
        titleAr: 'عرض', titleEn: 'Offer', bodyAr: 'نص', bodyEn: 'Body');
    expect(c.titleIn('en'), 'Offer');
    expect(c.bodyIn('en'), 'Body');
  });

  test('an untranslated row falls back to Arabic rather than going blank', () {
    // Deliberate. These rows are authored by an operator, and a notification
    // with no body is worse than one in the wrong language — the Arabic is
    // visible, so the gap can be seen and filled.
    final c = _campaign(titleAr: 'عرض', titleEn: '   ', bodyAr: 'نص', bodyEn: '');
    expect(c.titleIn('en'), 'عرض');
    expect(c.bodyIn('en'), 'نص');
  });

  test('an absent body stays absent in both languages', () {
    final c = _campaign(titleAr: 'عرض', titleEn: 'Offer');
    expect(c.bodyIn('ar'), isNull);
    expect(c.bodyIn('en'), isNull);
  });

  test('an unknown language code is treated as Arabic, the app default', () {
    final c = _campaign(titleAr: 'عرض', titleEn: 'Offer');
    expect(c.titleIn('fr'), 'عرض');
    expect(c.titleIn(''), 'عرض');
  });
}
