import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';

/// شريط تبويب حبة الدواء — سيطرة قطعية قابلة لإعادة الاستخدام.
///
/// iOS 26 style: no containing track — each tab is its own floating capsule.
/// The selected tab is a solid [c.cta] capsule; unselected tabs are real
/// liquid-glass capsules ([MaliGlass] — the native Apple material on iOS 26).
/// يستخدم [c.cta] للتبويب النشط، آمن في وضع RTL، ودعم إمكانية الوصول.
/// لا يعتمد على [TabController] أو أي شاشة بعينها.
class AppPillTabBar extends StatelessWidget {
  const AppPillTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    this.height = 44,
    this.advanced = false,
  });

  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final double height;

  /// Routes the unselected capsules through MaliGlass's advanced shader
  /// tier. Pilot-gated: only the Transactions pinned strip sets this (inside
  /// a [MaliGlassRegion] so the capsules share one render pass).
  final bool advanced;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.s2),
            Expanded(
              child: Semantics(
                label: tabs[i],
                selected: selectedIndex == i,
                button: true,
                onTap: () => onSelected(i),
                excludeSemantics: true,
                child: selectedIndex == i
                    ? GestureDetector(
                        onTap: () => onSelected(i),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          decoration: BoxDecoration(
                            color: c.cta,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            tabs[i],
                            textAlign: TextAlign.center,
                            style: AppTypography.caption(Colors.white)
                                .copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      )
                    : MaliGlass(
                        variant: MaliGlassVariant.pill,
                        advancedRefraction: advanced,
                        padding: EdgeInsets.zero,
                        onTap: () => onSelected(i),
                        child: Center(
                          child: Text(
                            tabs[i],
                            textAlign: TextAlign.center,
                            style: AppTypography.caption(c.textMuted)
                                .copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
