import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';
import '../mali_tokens.dart';
import '../../utils/app_lucide_icons.dart';

/// AttentionCard — a single, prioritized alert on the canvas (e.g. "٣ عمليات
/// في انتظار مراجعتك"). Tinted by [color] (defaults to warning). Strict
/// priority — the caller shows at most one; see design doc §0.7. Pure
/// presentation.
class AttentionCard extends StatelessWidget {
  const AttentionCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.color,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final tone = color ?? c.warning;
    final radius = BorderRadius.circular(AppRadius.xxxl);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.10),
            borderRadius: radius,
            border: Border.all(color: tone.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: tone, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTypography.bodyStrong(t.textOnCanvasPrimary),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: AppTypography.caption(t.textOnCanvasSecondary),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                Icon(AppLucideIcons.chevronLeft, color: tone, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
