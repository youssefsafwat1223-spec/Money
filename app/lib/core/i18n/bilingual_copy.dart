import '../../data/catalog/catalog_daos.dart';

/// Server-authored copy, in the reader's language, WITHOUT a `BuildContext`.
///
/// Announcement and growth-campaign rows carry both an Arabic and an English
/// field. Widgets choose between them through `Localizations.localeOf` — but
/// notifications are composed where there is no element tree, so the same rows
/// have to be readable from a plain language code.
///
/// The rule lives here exactly once. When it lived at each call site, four
/// surfaces chose independently and one of them chose wrong: `ForceUpdateScreen`
/// read `titleAr`, `bodyAr` AND `actionLabelAr`, so an English reader was
/// blocked by a screen they could not read. `features/announcements/announcement_text.dart`
/// is now a thin `BuildContext` adapter over these, so a widget and a
/// notification built from the same row can never disagree.
///
/// ## The fallback is deliberate
///
/// An empty English field falls back to Arabic rather than rendering blank. A
/// row whose translation the operator has not filled in yet should still say
/// something — a notification with no body is worse than one in the wrong
/// language, and the operator can see the Arabic and fix it.
String pickBilingual(String ar, String? en, String languageCode) {
  if (languageCode != 'en') return ar;
  final value = en?.trim();
  return (value == null || value.isEmpty) ? ar : value;
}

/// As [pickBilingual], for a field that may legitimately be absent in both
/// languages.
String? pickBilingualOptional(String? ar, String? en, String languageCode) {
  if (languageCode != 'en') return ar;
  final value = en?.trim();
  if (value != null && value.isNotEmpty) return value;
  return ar;
}

extension RemoteAnnouncementCopy on RemoteAnnouncement {
  String titleIn(String languageCode) =>
      pickBilingual(titleAr, titleEn, languageCode);

  String? bodyIn(String languageCode) =>
      pickBilingualOptional(bodyAr, bodyEn, languageCode);

  String? actionLabelIn(String languageCode) =>
      pickBilingualOptional(actionLabelAr, actionLabelEn, languageCode);
}

extension RemoteGrowthCampaignCopy on RemoteGrowthCampaign {
  String titleIn(String languageCode) =>
      pickBilingual(titleAr, titleEn, languageCode);

  String? bodyIn(String languageCode) =>
      pickBilingualOptional(bodyAr, bodyEn, languageCode);

  String? actionLabelIn(String languageCode) =>
      pickBilingualOptional(actionLabelAr, actionLabelEn, languageCode);
}
