import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// One cell in a [CalmPageHeader] metric strip.
class CalmMetric {
  const CalmMetric({required this.label, required this.value});
  final String label;
  final String value;
}

/// CalmPageHeader — the shared top-of-page pattern for the whole app
/// (docs/MALI_DESIGN_SYSTEM.md).
///
/// A blue hero band (title + optional subtitle, leading/trailing action, big
/// amount statement, metric strip) that MELTS into the page background — the
/// blue dissolves vertically into the canvas instead of ending at a lip or a
/// hard edge (the mockup's «الهيدر سايح» language, same as the dashboard
/// hero). White content on the blue.
/// Every screen uses this one widget — edit it here and every page updates.
class CalmPageHeader extends StatelessWidget {
  const CalmPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.amount,
    this.currency,
    this.metrics,
    this.child,
    this.topInset = AppSpacing.headerTopInset,
    this.useSafeAreaTop = true,
    this.meltOverflow = _defaultMeltOverflow,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// Big statement amount (e.g. the period total). Rendered white on the blue.
  final String? amount;

  /// Smaller, secondary currency next to [amount].
  final String? currency;

  final List<CalmMetric>? metrics;

  /// Optional extra content rendered inside the blue after the metrics
  /// (e.g. the settings profile row) — white-on-blue like everything else.
  final Widget? child;

  /// Fallback top padding when [useSafeAreaTop] is false (e.g. the header is
  /// embedded, not at the screen top).
  final double topInset;

  /// When true (screens that extend under the status bar) the top padding is
  /// the real device safe-area inset + a small gap, so the title always clears
  /// the notch / Dynamic Island. A fixed inset can't — the island is ~59px.
  final bool useSafeAreaTop;

  /// كام بكسل الأزرق يكمّل تحت نهاية محتوى الهيدر — ده اللي بيوصّل اللون
  /// لنص الشاشة تقريبًا وبيخلي الذوبان يحصل خلف أول كروت الصفحة.
  ///
  /// **مهم:** الامتداد ده بيشتغل بس لما الهيدر والمحتوى يكونوا في نفس الـ
  /// sliver (يعني `ListView`/`Column` عادي)، لأن الـ Viewport بيرسم أول sliver
  /// فوق اللي بعده — ففي صفحات `NestedScrollView`/`CustomScrollView` متعددة
  /// الشرائح لازم `meltOverflow: 0` وإلا الأزرق هيغطّي كروت الصفحة.
  final double meltOverflow;

  static const double _defaultMeltOverflow = 220;

  /// لون حافة الهيدر السفلية لما `meltOverflow == 0` — [MeltTail] بيبدأ منه
  /// بالظبط فالتدرّج بيكمّل من غير لحام.
  static Color meltEdgeColor(bool isDark) =>
      isDark ? AppBrandBlue.strong : AppBrandBlue.mid;

  /// إجمالي طول الذوبان تحت الهيدر بالبكسل.
  static const double meltLength = 220;

  /// لون الذوبان عند مسافة [px] تحت حافة الهيدر — أي حاجة بتتحط في نص
  /// الذوبان (زي شريط التبويبات المثبّت) بتستخدمه عشان مايبانش لحام.
  static Color meltColorAt(BuildContext context, double px) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Color.lerp(meltEdgeColor(isDark), context.colors.bg,
        (px / meltLength).clamp(0.0, 1.0))!;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPad = useSafeAreaTop
        ? MediaQuery.paddingOf(context).top + AppSpacing.s2
        : topInset;
    // الأزرق بيكمل تحت حدود الهيدر نفسه (بيتـرسم قبل باقي عناصر الصفحة فبيبقى
    // وراها): كده الذوبان بيحصل خلف أول كروت الصفحة لحد نص الشاشة تقريبًا،
    // من غير شريط أزرق فاضي تحت المقاييس.
    // من غير امتداد، الذوبان لازم يخلص جوّه حدود الهيدر نفسه — فذيل أطول
    // شوية تحت المحتوى، والتلاشي يبدأ متأخر عشان مايبانش شريط أزرق باهت.
    final hasOverflow = meltOverflow > 0;
    const bottomPad = AppSpacing.s5;
    final fadeStart = hasOverflow ? 0.55 : 1.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          bottom: -meltOverflow,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                stops: const [0.0, 0.55, 1.0],
                // درجات واحدة من [AppBrandBlue] — مش ألوان مكتوبة هنا.
                colors: AppBrandBlue.headerStops(isDark),
              ),
            ),
            // الميلت: الأزرق بيدوب رأسيًا في خلفية الصفحة — مفيش لسان ولا حافة.
            // لما مفيش امتداد، الحافة السفلية بتتسطّح على [meltEdgeColor] عشان
            // [MeltTail] في محتوى الصفحة يكمّل التدرّج من غير خط فاصل.
            foregroundDecoration: BoxDecoration(
              gradient: hasOverflow
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, fadeStart, 1.0],
                      colors: [
                        c.bg.withValues(alpha: 0),
                        c.bg.withValues(alpha: 0),
                        c.bg,
                      ],
                    )
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.5, 1.0],
                      colors: [
                        meltEdgeColor(isDark).withValues(alpha: 0),
                        meltEdgeColor(isDark).withValues(alpha: 0.55),
                        meltEdgeColor(isDark),
                      ],
                    ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.gutter, topPad, AppSpacing.gutter, bottomPad),
              // White content on the blue hero. Icon leading/trailing that don't
              // hardcode a colour inherit white from here.
              child: IconTheme(
                data: const IconThemeData(color: Colors.white),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (leading != null) ...[
                          leading!,
                          const SizedBox(width: AppSpacing.s2),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                style: AppTypography.calmTitle(Colors.white)
                                    .copyWith(
                                        fontSize: 24, letterSpacing: -0.5),
                              ),
                              if (subtitle != null && subtitle!.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.caption(
                                      Colors.white.withValues(alpha: 0.72)),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (trailing != null) trailing!,
                      ],
                    ),
                    if (amount != null) ...[
                      const SizedBox(height: AppSpacing.s3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              amount!,
                              style: AppTypography.balanceHero(Colors.white)
                                  .copyWith(fontSize: 44),
                            ),
                            if (currency != null && currency!.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Text(
                                currency!,
                                style: AppTypography.title2(
                                        Colors.white.withValues(alpha: 0.82))
                                    .copyWith(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    if (metrics != null && metrics!.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.s3),
                      _MetricStrip(metrics: metrics!),
                    ],
                    if (child != null) ...[
                      const SizedBox(height: AppSpacing.s4),
                      child!,
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// MeltTail — خلفية ذوبان **مش بتاخد أي مساحة**: بتلفّ محتوى الصفحة وبترسم
/// تدرّج من حافة الهيدر الزرقا لخلفية الكانفاس ورا أول [height] بكسل من
/// المحتوى، فالكروت بتقعد على اللون بدل ما يقعد لوحده في فراغ.
///
/// بتتلفّ حوالين الـ scrollable اللي جاي بعد [CalmPageHeader] وهي
/// `meltOverflow: 0` (صفحات NestedScrollView/CustomScrollView) — لأن الشرائح
/// بترسم أول شريحة فوق اللي بعدها، فامتداد الهيدر نفسه كان هيغطّي المحتوى.
class MeltTail extends StatelessWidget {
  const MeltTail({super.key, required this.child, this.startAt = 0});

  final Widget child;

  /// كام بكسل من الذوبان اتغطّى فوق الودجت دي (زي شريط تبويبات مثبّت بين
  /// الهيدر والمحتوى) — الباقي بيتكمّل من نفس اللون بالظبط.
  final double startAt;

  @override
  Widget build(BuildContext context) {
    final remaining = CalmPageHeader.meltLength - startAt;
    if (remaining <= 0) return child;
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: remaining,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 1.0],
                  colors: [
                    CalmPageHeader.meltColorAt(context, startAt),
                    context.colors.bg,
                  ],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// شريحة من الذوبان بتتحط ورا ودجت مثبّتة بين الهيدر والمحتوى (زي شريط
/// التبويبات) — التدرّج بيكمّل من وراها بدل ما تبان خلفية الصفحة كلحام تحت
/// حافة الهيدر مباشرة. الـ [MeltTail] اللي بعدها لازم يبقى `startAt: height`.
class MeltSlice extends StatelessWidget {
  const MeltSlice({super.key, required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            CalmPageHeader.meltColorAt(context, 0),
            CalmPageHeader.meltColorAt(context, height),
          ],
        ),
      ),
      child: child,
    );
  }
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.metrics});
  final List<CalmMetric> metrics;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.s4, horizontal: AppSpacing.s2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            if (i > 0)
              Container(
                  width: 1,
                  height: 30,
                  color: Colors.white.withValues(alpha: 0.2)),
            Expanded(
              child: Column(
                children: [
                  Text(
                    metrics[i].value,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(Colors.white),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    metrics[i].label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // 11px per the mockup `.metastrip span` (caption is 12).
                    style: AppTypography.caption(
                            Colors.white.withValues(alpha: 0.72))
                        .copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
