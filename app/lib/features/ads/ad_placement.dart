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
/// V1 ships exactly ONE placement. Both reviewers of the banner plan
/// independently cut the rest, and for the same reason: a small number of
/// high-quality placements beats density, and a placement you cannot yet
/// measure is a placement you cannot yet justify.
enum AdPlacement {
  /// The transactions list, after the first complete date section.
  ///
  /// Chosen because it is the only surface in the app that is high-dwell,
  /// browsing-intent, and carries no destructive or financial-confirmation
  /// action. Everything else either asks the user to decide about money or is
  /// somewhere an ad would read as a recommendation.
  transactionsList('transactions_list');

  const AdPlacement(this.key);

  /// The stable analytics/flag key. Deliberately not `name` — a Dart identifier
  /// rename would otherwise silently change a remote flag key and an analytics
  /// dimension at the same time.
  final String key;
}

/// Resolves a placement to its ad unit.
///
/// V1 maps every placement to the single configured banner unit because V1 has
/// one placement. The moment a second placement is approved it should get its
/// own unit: per-placement units are the only way AdMob reporting can answer
/// "is this placement worth keeping", and a shared unit makes that
/// unanswerable. This function is where that change goes.
String? bannerUnitFor(AdPlacement placement, TargetPlatform platform) {
  switch (placement) {
    case AdPlacement.transactionsList:
      return AdMobBuildConfig.bannerUnitId(platform);
  }
}
