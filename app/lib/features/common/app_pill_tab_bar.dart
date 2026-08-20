import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// شريط تبويب حبة الدواء — سيطرة قطعية قابلة لإعادة الاستخدام.
///
/// iOS 26 style: no containing track — each tab is its own floating capsule.
/// المختار كبسولة ink صلبة (أسود في الفاتح، أبيض في الداكن)، وغير المختار
/// كبسولة سطح عادي بحدّ خفيف — من غير زجاج.
/// آمن في وضع RTL، ودعم إمكانية الوصول.
/// لا يعتمد على [TabController] أو أي شاشة بعينها.
class AppPillTabBar extends StatelessWidget {
  const AppPillTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    this.height = 44,
  });

  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final double height;

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
                            color: c.ink,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            tabs[i],
                            textAlign: TextAlign.center,
                            style: AppTypography.caption(c.onInk)
                                .copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      )
                    : GestureDetector(
                        onTap: () => onSelected(i),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: Border.all(color: c.divider),
                          ),
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
            ),
          ],
        ],
      ),
    );
  }
}
