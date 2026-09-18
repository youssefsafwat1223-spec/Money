import 'package:flutter/widgets.dart';

import '../../core/i18n/bilingual_copy.dart';
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
///
/// That rule now lives in `core/i18n/bilingual_copy.dart`, which needs no
/// `BuildContext` — because the same rows are also read where there is no
/// element tree at all: `NotificationJourneyService` composes campaign
/// notifications from a background-safe service. This file is the widget
/// adapter over it, so a banner and a notification built from the same row
/// cannot disagree about which language they are in.
String _language(BuildContext context) =>
    Localizations.localeOf(context).languageCode;

extension RemoteAnnouncementText on RemoteAnnouncement {
  String titleFor(BuildContext context) => titleIn(_language(context));

  String? bodyFor(BuildContext context) => bodyIn(_language(context));

  String? actionLabelFor(BuildContext context) =>
      actionLabelIn(_language(context));
}

extension RemoteGrowthCampaignText on RemoteGrowthCampaign {
  String titleFor(BuildContext context) => titleIn(_language(context));

  String? bodyFor(BuildContext context) => bodyIn(_language(context));

  String? actionLabelFor(BuildContext context) =>
      actionLabelIn(_language(context));
}
