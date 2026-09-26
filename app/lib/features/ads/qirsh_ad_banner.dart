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

  /// The width the current controller asked for.
  ///
  /// An anchored adaptive banner's height is derived from the width at REQUEST
  /// time, and the creative that comes back is sized for it. Nothing about it
  /// re-adapts afterwards — so an ad loaded in landscape and carried into
  /// portrait keeps its old dimensions while Flutter squeezes the box around
  /// it. Keeping the requested width is what makes that detectable.
  int? _requestedWidthPx;

  /// The one-shot wait for a throttled slot.
  ///
  /// A request refused by the 30-second throttle leaves a terminally failed
  /// controller, and the widget holds it — so the slot stays blank until
  /// something rebuilds the widget from scratch. Waiting past the window does
  /// nothing on its own. This is what turns the wait into a retry: when the
  /// window closes, the dead controller is dropped and the ordinary build path
  /// asks again, with whatever gates and width are true THEN.
  Timer? _retryTimer;

  /// Exactly one retry per mount. A second refusal means the placement is
  /// genuinely busy, and retrying again would be the request loop the throttle
  /// exists to prevent.
  bool _retried = false;

  void _disposeController() {
    _controller?.dispose();
    _controller = null;
  }

  /// Every gate that `build` checked, re-read right now.
  ///
  /// `build` decides, a post-frame callback acts, and a frame boundary sits
  /// between them. In that gap the shell tab can change, a route can be pushed,
  /// a sheet can open, or the entitlement future can complete as ad-free — and
  /// the decision that scheduled the request was made before any of that.
  ///
  /// Nothing here is expensive: three synchronous lookups and a `ref.read`. It
  /// is the eligibility one that matters most, because the cost of getting it
  /// wrong is showing an ad to someone who paid not to see one.
  bool get _gatesStillOpen {
    if (!mounted) return false;
    if (!Visibility.of(context)) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (modalRouteOpen.value) return false;
    return ref.read(bannerEligibilityProvider(widget.placement)).valueOrNull ==
        true;
  }

  /// Start exactly one request, if every gate is open. Called from `build` via
  /// a post-frame callback so the available width is known.
  void _maybeRequest(double width) {
    if (_controller != null) return;
    if (!_gatesStillOpen) return;
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
    _requestedWidthPx = width.floor();
    controller.addListener(_onControllerChanged);
    // Fire-and-forget: the controller notifies when it reaches a terminal
    // state, and every failure path inside it is silent by design.
    controller.request(adUnitId: unitId, widthPx: width.floor());
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _scheduleRetryIfThrottled();
    setState(() {});
  }

  /// Arm the one-shot retry.
  ///
  /// Two causes qualify, and both are the ABSENCE of an answer rather than an
  /// answer:
  ///
  ///   * the per-placement throttle refused the request outright;
  ///   * our own client-side timer gave up before the SDK replied.
  ///
  /// A no-fill or a reported load failure is a real answer and still gets no
  /// retry — `onAdFailedToLoad` fired, the network said no, and asking again
  /// immediately would be both pointless and impolite.
  ///
  /// The timeout case is what makes a cold start recoverable. The first request
  /// after `MobileAds.initialize()` was measured at 20072ms against warm loads
  /// of 492-1945ms, so it lost the 20s race and the slot collapsed for the whole
  /// mount. Now it collapses, waits out the throttle, and asks once more — which
  /// lands in the warm case.
  void _scheduleRetryIfThrottled() {
    if (_retried || _retryTimer != null) return;
    final controller = _controller;
    if (controller == null) return;
    if (!controller.throttleRefused && !controller.loadTimedOut) return;
    // Even a timeout waits for the throttle window: one slow request is not a
    // licence to bypass the per-placement rate limit.
    final wait = controller.throttleRemaining ?? Duration.zero;

    _retryTimer = Timer(wait + const Duration(milliseconds: 50), () {
      _retryTimer = null;
      if (!mounted) return;
      _retried = true;
      // Drop the dead controller and nothing else. Every gate — offstage,
      // route, modal, entitlement, consent, the flags, the Reports
      // suppression — and the current width are re-evaluated by the normal
      // build path that follows, because that is the path that owns them. A
      // gate that closed while we waited simply means no request happens.
      _controller?.removeListener(_onControllerChanged);
      _disposeController();
      _requestedWidthPx = null;
      setState(() {});
    });
  }

  /// Publish how tall the ad band currently is, after the frame.
  ///
  /// ZERO is as important as any other value. This provider is only ever read
  /// by a screen painting a melt gradient behind the band, and it was previously
  /// written ONLY when a slot appeared — never when one went away. So once an ad
  /// had shown, the extent stayed at its last value forever, and a screen with
  /// no ad on it went on reserving melt for a band that was not there. On
  /// Reports that showed up as the blue cutting off hard above the tab row.
  void _reportExtent(double extent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final n = ref.read(headerAdExtentProvider(widget.placement).notifier);
      if (n.state != extent) n.state = extent;
    });
  }

  /// Drop the controller and any ad it holds, after the current frame.
  ///
  /// Deferred because this is reached from `build`, and disposing a platform
  /// view mid-build is not safe. Idempotent — every gate can call it freely.
  void _tearDownAfterFrame() {
    // BEFORE the early return. A placement whose gate closed without ever
    // having had a controller — no ad yet, or not eligible at all — still has
    // to retract any melt the screen is reserving for it, and that is the
    // common case on arrival rather than an edge case.
    _reportExtent(0);
    if (_controller == null) return;
    // A pending retry belongs to the controller being dropped. Whatever closed
    // the gate here will re-open the normal request path if it re-opens at all.
    _retryTimer?.cancel();
    _retryTimer = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller?.removeListener(_onControllerChanged);
      _disposeController();
      _requestedWidthPx = null;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
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

        // The LayoutBuilder wraps EVERY state, not just the un-requested one.
        // It used to guard only the request, so once a controller existed the
        // available width was never looked at again — a banner loaded at one
        // width rendered at its old size for the rest of its life, whatever the
        // box around it did. Rotation and any resize hit that.
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final controller = _controller;

            if (controller == null) {
              if (width.isFinite && width > 0) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _maybeRequest(width);
                });
              }
              _reportExtent(0);
              return const SizedBox.shrink();
            }

            // The width moved under a live request. Drop the creative rather
            // than paint one sized for a box that no longer exists; the next
            // build re-requests at the new width, and the ordinary throttle
            // applies to that request like any other.
            final requested = _requestedWidthPx;
            if (width.isFinite &&
                requested != null &&
                width.floor() != requested) {
              _tearDownAfterFrame();
              return const SizedBox.shrink();
            }

            // Height first, creative second. The slot takes its space as soon
            // as the size is RESOLVED, so the page stops growing under a reader
            // who has already reached the end of it; the ad then paints into
            // space that was already waiting. Null height means idle or failed,
            // and those collapse.
            final height = controller.heightPx;
            if (height == null) {
              // Idle or failed: no band, so no melt is reserved for one.
              _reportExtent(0);
              return const SizedBox.shrink();
            }
            final ad = controller.ad;
            final slot = _BannerSlot(
              height: height.toDouble(),
              ad: ad is BannerAd ? ad : null,
              // How tall the band is, reported for whoever paints behind it.
              // The Reports and Subscriptions headers use it to continue their
              // melt gradient past the ad; nothing reads it to decide whether
              // an ad may serve. Reported after the frame, because writing
              // provider state during a build is not allowed.
              onExtent: _reportExtent,
            );
            // The melt behind a header band is painted by the SCREEN, not
            // here: it has to run the full width of the page, and this widget
            // is mounted inside the gutter padding. All this does is report how
            // tall the band is.
            return slot;
          },
        );
      },
    );
  }
}

/// The slot's total extent for a given ad height: the ad, the label above it
/// and the padding around both. Kept next to the layout it describes.
double _slotExtent(double adHeight) =>
    adHeight + _labelBlock + AppSpacing.s5 * 2;

/// Caption line plus its bottom padding. Close enough for a gradient stop; it
/// is not used for layout.
const double _labelBlock = 22;

/// The loaded banner, with its label and its separation from whatever is above
/// and below it.
class _BannerSlot extends StatefulWidget {
  const _BannerSlot({
    required this.height,
    required this.ad,
    this.onExtent,
  });

  final double height;
  final ValueChanged<double>? onExtent;

  /// Null while the request is still in flight. The slot renders at its full
  /// size either way — that is the point — but with nothing in it and no label,
  /// so a waiting slot reads as blank space rather than as a failed ad.
  final BannerAd? ad;

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
    final waiting = ad == null;
    widget.onExtent?.call(_slotExtent(height));
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
          // Kept in the layout while waiting, so the reserved height is the
          // SAME height the loaded slot will have and nothing shifts when the
          // creative lands. Invisible, because "Advertisement" over an empty
          // box reads as an ad that failed.
          Opacity(
            opacity: waiting ? 0 : 1,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                context.l10n.adLabel,
                textAlign: TextAlign.center,
                style: AppTypography.caption(c.textMuted),
              ),
            ),
          ),
          SizedBox(
            height: height,
            child: waiting
                ? const SizedBox.shrink()
                : Center(
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
