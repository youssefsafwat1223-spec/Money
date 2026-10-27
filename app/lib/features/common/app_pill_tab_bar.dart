import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';

/// شريط تبويب حبة الدواء — سيطرة قطعية قابلة لإعادة الاستخدام.
///
/// iOS 26 segmented style: one glass track ([MaliGlass] pill) with a sliding
/// glass lens under the selected tab — no solid ink fill (the owner rejected
/// the black/white selection as foreign to the blue system). In light the
/// lens is tinted with the app blue; in dark it is a brighter white glass.
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

  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lensFill = dark
        ? Colors.white.withValues(alpha: 0.22)
        : c.ink.withValues(alpha: 0.14);
    final lensBorder = dark
        ? Colors.white.withValues(alpha: 0.45)
        : c.ink.withValues(alpha: 0.35);
    final selectedFg = dark ? Colors.white : AppBrandBlue.brand;
    final idleFg = dark ? Colors.white.withValues(alpha: 0.72) : c.textSecondary;
    final count = tabs.length;
    final x = count < 2 ? 0.0 : -1 + 2 * selectedIndex / (count - 1);

    return SizedBox(
      height: height,
      child: MaliGlass(
        variant: MaliGlassVariant.pill,
        padding: const EdgeInsets.all(_inset),
        child: Stack(
          children: [
            if (count > 0)
              Positioned.fill(
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  alignment: AlignmentDirectional(x, 0),
                  child: FractionallySizedBox(
                    widthFactor: 1 / count,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: lensFill,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(color: lensBorder),
                      ),
                    ),
                  ),
                ),
              ),
            Row(
              children: [
                for (var i = 0; i < count; i++)
                  Expanded(
                    child: Semantics(
                      label: tabs[i],
                      selected: selectedIndex == i,
                      button: true,
                      onTap: () => onSelected(i),
                      excludeSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelected(i),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 180),
                            style: AppTypography.caption(
                              selectedIndex == i ? selectedFg : idleFg,
                            ).copyWith(fontWeight: FontWeight.w700),
                            child: Text(
                              tabs[i],
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
