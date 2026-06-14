import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';

enum BentoTheme { dark, accent, success, glass }

class BentoCard extends StatelessWidget {
  const BentoCard({
    super.key,
    required this.child,
    this.theme = BentoTheme.glass,
    this.padding = const EdgeInsets.all(AppSpacing.s4),
    this.onTap,
  });

  final Widget child;
  final BentoTheme theme;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    
    Color? bgColor;
    Color? borderColor;
    Gradient? gradient;
    
    switch (theme) {
      case BentoTheme.dark:
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.primary, const Color(0xFF103B66)],
        );
        break;
      case BentoTheme.accent:
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.accent, c.primary],
        );
        break;
      case BentoTheme.success:
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.success, const Color(0xFF10B981)],
        );
        break;
      case BentoTheme.glass:
        bgColor = c.surface;
        borderColor = c.border;
        break;
    }

    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bgColor,
        gradient: gradient,
        borderRadius: BorderRadius.circular(24),
        border: borderColor != null ? Border.all(color: borderColor) : null,
        boxShadow: [
          BoxShadow(
            color: c.primary.withValues(alpha: 0.04),
            blurRadius: 15,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: card,
      );
    }
    return card;
  }
}

class BentoRow extends StatelessWidget {
  const BentoRow({super.key, required this.children, this.flexes});
  
  final List<Widget> children;
  final List<int>? flexes;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          Expanded(
            flex: flexes != null && i < flexes!.length ? flexes![i] : 1,
            child: children[i],
          ),
          if (i < children.length - 1) const SizedBox(width: AppSpacing.s3),
        ],
      ],
    );
  }
}
