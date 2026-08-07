import 'package:flutter/material.dart';

import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// True while the app is doing blocking startup work the user must not see
/// half-populated — specifically the post-sign-in data restore, when the local
/// DB still holds reseeded defaults until the first pull lands.
///
/// A single full-screen branded loader (identical to the cold-start screen) is
/// shown at the APP ROOT while this is true — above the router, so it stays put
/// through the StartupApp→shell handoff and any route transition. Result: one
/// continuous loading screen from launch to data-ready, not the shell flashing
/// defaults behind a second loader.
final ValueNotifier<bool> appDataRestoring = ValueNotifier<bool>(false);

/// B2-C — the explicit "first usable local financial state" milestone. Flipped
/// true by the bootstrap the moment the SAFETY-CRITICAL phase is done: DB key +
/// encrypted DB open + required migration/repair + process/owner liveness +
/// admission (owner-conflict) resolved + seed — i.e. repositories can run a real
/// owner-scoped query. It does NOT wait for network (remote feature/config
/// refresh, remote-backup metadata), analytics, or non-critical
/// diagnostics/cleanup — those run in the deferred phase AFTER this flips. The
/// financial UI is only shown once the local DB is genuinely the current owner's,
/// never previous-user cached data (that is the [appDataRestoring] gate's job).
final ValueNotifier<bool> localFinancialUiUsable = ValueNotifier<bool>(false);

/// The one branded loading view (logo + slim accent spinner). Matches
/// `StartupLoadingScreen._LoadingBody` exactly so the cold-start screen and the
/// restore overlay are indistinguishable.
class AppBootLoader extends StatelessWidget {
  const AppBootLoader({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: ColoredBox(
        color: c.bg,
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  AppAssets.getLogoTagline(context),
                  width: 220,
                  filterQuality: FilterQuality.high,
                ),
                const SizedBox(height: AppSpacing.s8),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(c.accent),
                  ),
                ),
                const SizedBox(height: AppSpacing.s5),
                Text('جاري تجهيز التطبيق...',
                    style: AppTypography.callout(c.textLight)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
