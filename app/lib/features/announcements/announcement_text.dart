import 'package:flutter/widgets.dart';

import '../../data/catalog/catalog_daos.dart';

/// Server-authored announcement and campaign copy, in the reader's language.
///
/// Every row carries both an Arabic and an English field. Four surfaces read the
/// Arabic one unconditionally:
///
///  * `ForceUpdateScreen` — title, body AND action label. It blocks the entire
///    app, so an English reader was stopped by a screen they could not read,
///    with no way past it. Captured on an English device, the frame came back
///    byte-for-byte identical to the Arabic one.
///  * the dashboard `AnnouncementBanner` — title, body and action, for both
///    announcements and growth campaigns. This is the first thing on the first
///    screen.
///  * `AnnouncementsScreen.fromAnnouncement` — the action label only, on the
///    line directly below two that chose correctly.
///
/// None of it was ever visible to the bilingual walk, because the QA catalog
/// seeds zero announcements. An empty surface has no copy to measure, so "0
/// untranslated strings" was true and meaningless here at the same time.
///
/// The fallback is deliberate: an empty English field falls back to Arabic
/// rather than rendering a blank banner. A row whose translation the operator
/// has not filled in yet should still say something.
String _pick(String ar, String? en, bool english) {
  if (!english) return ar;
  final value = en?.trim();
  return (value == null || value.isEmpty) ? ar : value;
}

String? _pickOptional(String? ar, String? en, bool english) {
  if (!english) return ar;
  final value = en?.trim();
  if (value != null && value.isNotEmpty) return value;
  return ar;
}

/// True when the reader's language is English.
bool _isEnglish(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'en';

extension RemoteAnnouncementText on RemoteAnnouncement {
  String titleFor(BuildContext context) =>
      _pick(titleAr, titleEn, _isEnglish(context));

  String? bodyFor(BuildContext context) =>
      _pickOptional(bodyAr, bodyEn, _isEnglish(context));

  String? actionLabelFor(BuildContext context) =>
      _pickOptional(actionLabelAr, actionLabelEn, _isEnglish(context));
}

extension RemoteGrowthCampaignText on RemoteGrowthCampaign {
  String titleFor(BuildContext context) =>
      _pick(titleAr, titleEn, _isEnglish(context));

  String? bodyFor(BuildContext context) =>
      _pickOptional(bodyAr, bodyEn, _isEnglish(context));

  String? actionLabelFor(BuildContext context) =>
      _pickOptional(actionLabelAr, actionLabelEn, _isEnglish(context));
}
