import 'package:flutter/foundation.dart';

import 'admob_build_config.dart';

/// Where a banner may appear, as a stable semantic identity.
///
/// The enum — not an ad-unit string — is what feature code names. A literal
/// AdMob unit id must never appear in a feature file: it makes a placement
/// impossible to disable independently, impossible to report on, and it puts a
/// production identifier in a screen's source. (Written without the literal
/// publisher prefix on purpose — the guard test that enforces this greps for
/// it, and prose is not an exemption.)
///
/// **This enum is the APPROVED list, not the MOUNTED list.** A value here means
/// an owner decision permits a banner on that surface; it does not mean one is
/// rendered yet, and it certainly does not mean one is enabled — every
/// placement is seeded OFF in `_defaults` and activated remotely, one key at a
/// time. The call-site allowlist in `report_ads_guards_test.dart` is the
/// separate, narrower record of what is actually mounted today.
///
/// Widened from one placement to six by owner decision **D-19 (2026-09-19)**,
/// which supersedes D-18's two-surface allowlist. D-18's reasoning — that a
/// small number of high-quality placements beats density — is not repudiated;
/// what changed is that the owner, who carries the revenue decision, widened
/// the set. The structural constraints D-18 established all survive: closed
/// allowlist, no raw unit ids, fail-closed flags, no ad beside a financial
/// confirmation or a destructive action.
enum AdPlacement {
  /// The transactions list, after the first complete date section.
  ///
  /// High-dwell, browsing-intent, and carries no destructive or financial
  /// confirmation action.
  transactionsList('transactions_list'),

  /// The dashboard / home tab.
  ///
  /// Excluded by D-18, approved by D-19. The surface itself is a summary read,
  /// not a decision point — but it is also the first screen after launch, which
  /// is why it gets its own flag and will not be activated at the same time as
  /// the others.
  dashboard('dashboard'),

  /// The goals list screen (`/goals`), not goal detail and not the goal form.
  goals('goals'),

  /// The subscriptions / bills screen (`/subscriptions`), list content only —
  /// never inside the bill form or the payment-attempt sheet.
  subscriptions('subscriptions'),

  /// The reports tab (shell index 4).
  ///
  /// The only surface carrying two formats: this banner AND the pre-existing
  /// report-export interstitial (D-18, preserved). Those two must not be able
  /// to fire around the same export — sequencing is part of the surface plan,
  /// not of this identity.
  reports('reports'),

  /// The achievements screen (`/achievements`).
  achievements('achievements');

  const AdPlacement(this.key);

  /// The stable analytics/flag key. Deliberately not `name` — a Dart identifier
  /// rename would otherwise silently change a remote flag key and an analytics
  /// dimension at the same time.
  final String key;

  /// The remote flag that governs this placement alone.
  ///
  /// Single source of the spelling. `bannerPlacementEnabledProvider` reads it,
  /// `_defaults` must seed it, and a guard test derives the required default
  /// keys from here — so a new placement cannot ship with a flag key that
  /// exists in only one of those three places.
  String get flagKey => 'enable_banner_$key';
}

/// Resolves a placement to its ad unit.
///
/// Every placement maps to the single configured banner unit. The earlier note
/// here said a second placement "should get its own unit" for reporting — that
/// remains true as reporting advice and is deliberately NOT acted on: a
/// per-placement unit means a new `ADMOB_*` build input, a new Codemagic
/// variable and a new AdMob ad unit, and the owner has placed AdMob release
/// configuration out of scope (2026-09-19). Per-placement measurement is
/// available meanwhile through the placement-keyed analytics events, which cost
/// no build inputs.
String? bannerUnitFor(AdPlacement placement, TargetPlatform platform) {
  switch (placement) {
    case AdPlacement.transactionsList:
    case AdPlacement.dashboard:
    case AdPlacement.goals:
    case AdPlacement.subscriptions:
    case AdPlacement.reports:
    case AdPlacement.achievements:
      return AdMobBuildConfig.bannerUnitId(platform);
  }
}
