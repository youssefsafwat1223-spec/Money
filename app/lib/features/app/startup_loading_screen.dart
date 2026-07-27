import 'package:flutter/material.dart';

import '../../core/startup/bootstrap_runner.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';

/// Shown by `runApp()` immediately on cold start, before real async
/// initialization (DB open, session restore, feature flags, ...) has
/// finished. Never shown again after the first successful bootstrap — normal
/// navigation, resume, and background sync use inline/silent indicators
/// instead (see `docs/` refresh policy notes).
class StartupLoadingScreen extends StatelessWidget {
  const StartupLoadingScreen({
    super.key,
    required this.onRetry,
    this.error,
    this.lastStep,
  });

  /// Non-null once bootstrap has failed or timed out — switches the screen
  /// to the retry state.
  final Object? error;

  /// Name of the bootstrap step that was running when [error] occurred, for
  /// the optional diagnostic identifier. Never contains user data.
  final String? lastStep;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              child: error == null
                  ? const _LoadingBody()
                  : _ErrorBody(
                      error: error!,
                      lastStep: lastStep,
                      onRetry: onRetry,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
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
        Text(
          'جاري تجهيز التطبيق...',
          style: AppTypography.callout(c.textLight),
        ),
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({
    required this.error,
    required this.lastStep,
    required this.onRetry,
  });

  final Object error;
  final String? lastStep;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isTimeout = error is BootstrapTimeoutException;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: c.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.primary.withValues(alpha: 0.22)),
          ),
          child: Icon(
            AppLucideIcons.alertTriangle,
            color: c.primary,
            size: 34,
          ),
        ),
        const SizedBox(height: AppSpacing.s5),
        Text(
          isTimeout
              ? 'استغرق التجهيز وقتاً أطول من المتوقع'
              : 'تعذّر تجهيز التطبيق',
          textAlign: TextAlign.center,
          style: AppTypography.headline(c.textMain),
        ),
        const SizedBox(height: AppSpacing.s2),
        Text(
          'تأكد من اتصالك بالإنترنت وحاول مرة أخرى.',
          textAlign: TextAlign.center,
          style: AppTypography.callout(c.textLight),
        ),
        if (lastStep != null) ...[
          const SizedBox(height: AppSpacing.s2),
          Text(
            'معرّف: $lastStep',
            textAlign: TextAlign.center,
            style: AppTypography.caption(c.textLight),
          ),
        ],
        const SizedBox(height: AppSpacing.s5),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: onRetry,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: c.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('إعادة المحاولة'),
          ),
        ),
      ],
    );
  }
}
