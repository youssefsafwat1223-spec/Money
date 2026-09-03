import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show AdWidget, BannerAd;

import '../../core/router/modal_route_observer.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import 'ad_placement.dart';
import 'banner_ad_controller.dart';
import 'banner_ads_providers.dart';

/// The ONE banner surface in the app.
///
/// Feature screens name a [AdPlacement] and nothing else. They never see a
/// `BannerAd`, an `AdSize`, an ad-unit id, a consent object or an entitlement
/// state — all of that is behind this widget, and an architecture test asserts
/// that no Google Mobile Ads symbol appears outside `features/ads/`.
///
/// ## It renders nothing until it renders an ad
///
/// Zero height in every state except `loaded`. No placeholder, no skeleton, no
/// "Advertisement" frame around empty space. An empty bordered box in a finance
/// app does not read as a pending ad; it reads as a screen that failed to load,
/// and it is the first thing a user reports as a bug.
///
/// ## Visual gates
///
/// Three of them, all of which only the widget can see:
///
///  * **Offstage.** The app shell is an `IndexedStack`, which wraps every child
///    in `Visibility(maintainSize: true, maintainState: true)`. That path keeps
///    non-selected tabs LAID OUT and merely skips painting them, and it does
///    not disable `TickerMode` — so a naive banner on a background tab would be
///    built, sized, and would request an ad the user cannot see.
///    `Visibility.of(context)` is the framework's own answer: it walks every
///    ancestor visibility scope and registers a dependency, so this rebuilds
///    the moment the tab becomes hidden or visible.
///  * **Covered by a pushed route.** `ModalRoute.isCurrent`.
///  * **Covered by a sheet or dialog.** `AdWidget` is a platform view. This
///    app already learned that platform views bleed over Flutter modals — the
///    shell drops its own nav bar while `modalRouteOpen` is true for exactly
///    that reason. A banner sitting under an open transaction sheet would be an
///    ad drawn on top of app content, which is a placement-policy violation and
///    not merely ugly.
class QirshAdBanner extends ConsumerStatefulWidget {
  const QirshAdBanner({super.key, required this.placement});

  final AdPlacement placement;

  @override
  ConsumerState<QirshAdBanner> createState() => _QirshAdBannerState();
}

class _QirshAdBannerState extends ConsumerState<QirshAdBanner> {
  BannerAdController? _controller;

  void _disposeController() {
    _controller?.dispose();
    _controller = null;
  }

  /// Start exactly one request, if every gate is open. Called from `build` via
  /// a post-frame callback so the available width is known.
  void _maybeRequest(double width) {
    if (_controller != null) return;
    final unitId = bannerUnitFor(widget.placement, defaultTargetPlatform);
    if (unitId == null) return;

    final controller = BannerAdController(
      placement: widget.placement,
      loader: ref.read(bannerAdLoaderFactoryProvider)(),
      // Resolved LAZILY, at emit time, not at construction. The analytics sink
      // needs user settings for its consent gate, which reaches the database
      // provider graph — and a banner that is suppressed, throttled or too
      // narrow must do no work at all, including not building a telemetry
      // object it will never use.
      onEvent: (event, placementKey) =>
          ref.read(bannerAdsAnalyticsProvider).record(event, placementKey),
    );
    _controller = controller;
    controller.addListener(_onControllerChanged);
    // Fire-and-forget: the controller notifies when it reaches a terminal
    // state, and every failure path inside it is silent by design.
    controller.request(adUnitId: unitId, widthPx: width.floor());
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// Drop the controller and any ad it holds, after the current frame.
  ///
  /// Deferred because this is reached from `build`, and disposing a platform
  /// view mid-build is not safe. Idempotent — every gate can call it freely.
  void _tearDownAfterFrame() {
    if (_controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller?.removeListener(_onControllerChanged);
      _disposeController();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Registers a dependency on every ancestor Visibility — this rebuilds when
    // the shell tab changes.
    final onstage = Visibility.of(context);
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;

    return ValueListenableBuilder<bool>(
      valueListenable: modalRouteOpen,
      builder: (context, modalOpen, _) {
        final visible = onstage && routeIsCurrent && !modalOpen;
        if (!visible) {
          // Drop the ad entirely rather than holding a hidden one. Holding it
          // would mean a native view attached to a screen the user is not
          // looking at, which is the thing this whole gate exists to prevent.
          _tearDownAfterFrame();
          return const SizedBox.shrink();
        }

        final eligible =
            ref.watch(bannerEligibilityProvider(widget.placement)).valueOrNull;
        // Null means the entitlement/consent lookup has not answered yet. Not
        // eligible: an ad-free user must never see even a momentary slot.
        if (eligible != true) {
          // ...and if we ALREADY hold an ad when eligibility turns false, drop
          // it now. This path used to return an empty box while keeping the ad
          // alive, so a user who earned ad-free mid-session — or revoked UMP
          // consent — still had a loaded banner held behind the scenes. Only
          // the visual gate disposed; the entitlement gate did not.
          _tearDownAfterFrame();
          return const SizedBox.shrink();
        }

        final controller = _controller;
        if (controller == null) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              if (width.isFinite && width > 0) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _maybeRequest(width);
                });
              }
              return const SizedBox.shrink();
            },
          );
        }

        final height = controller.heightPx;
        final ad = controller.ad;
        if (controller.status != BannerAdStatus.loaded ||
            height == null ||
            ad is! BannerAd) {
          return const SizedBox.shrink();
        }
        return _BannerSlot(height: height.toDouble(), ad: ad);
      },
    );
  }
}

/// The loaded banner, with its label and its separation from whatever is above
/// and below it.
class _BannerSlot extends StatefulWidget {
  const _BannerSlot({required this.height, required this.ad});

  final double height;
  final BannerAd ad;

  @override
  State<_BannerSlot> createState() => _BannerSlotState();
}

class _BannerSlotState extends State<_BannerSlot> {
  /// Taps are ignored for a moment after the slot appears.
  ///
  /// Insert-when-loaded means content below moves DOWN once, and a finger
  /// already descending toward a transaction row would land on the ad instead —
  /// which is precisely the accidental click Google's placement guidance
  /// penalises. Reserving space instead would trade this for an empty box on
  /// every no-fill, which is worse in a finance app. So: keep the sequencing,
  /// and make the first moment after insertion a dead zone.
  static const _tapShield = Duration(milliseconds: 800);

  bool _acceptsTaps = false;
  Timer? _shieldTimer;

  @override
  void initState() {
    super.initState();
    _shieldTimer = Timer(_tapShield, () {
      if (mounted) setState(() => _acceptsTaps = true);
    });
  }

  @override
  void dispose() {
    _shieldTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final height = widget.height;
    final ad = widget.ad;
    return Padding(
      // Real vertical separation, both sides. The transactions list is made of
      // tappable rows that open a detail sheet; an ad flush against one is the
      // textbook accidental-click layout, and Google's discouraged-placements
      // guidance names it directly.
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Says whose content this is. Qirsh's own offer cards carry no such
          // label, so the label IS the distinction between a Qirsh
          // recommendation and a third-party advertisement.
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              context.l10n.adLabel,
              textAlign: TextAlign.center,
              style: AppTypography.caption(c.textMuted),
            ),
          ),
          SizedBox(
            height: height,
            child: Center(
              child: SizedBox(
                width: ad.size.width.toDouble(),
                height: height,
                child: IgnorePointer(
                  ignoring: !_acceptsTaps,
                  child: AdWidget(ad: ad),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
