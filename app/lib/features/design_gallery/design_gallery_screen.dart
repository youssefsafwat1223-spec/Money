import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lgr;

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/mali_tokens.dart';
import '../../core/theme/widgets/calm_chip.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/account_card.dart';
import '../../core/theme/widgets/attention_card.dart';
import '../../core/theme/widgets/balance_statement.dart';
import '../../core/theme/widgets/budget_ring_rail.dart';
import '../../core/theme/widgets/donut_chart.dart';
import '../../core/theme/widgets/glass_surface.dart';
import '../../core/theme/widgets/insight_card.dart';
import '../../core/theme/widgets/ledger_row.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/mali_screen.dart';
import '../../core/theme/widgets/merchant_bar.dart';
import '../../core/theme/widgets/pulse_row.dart';
import '../../core/theme/widgets/ring_progress.dart';
import '../../core/theme/widgets/score_gauge.dart';
import '../../core/theme/widgets/section_header.dart';
import '../../core/theme/widgets/segmented_control.dart';
import '../../core/theme/widgets/sheet_field.dart';
import '../../core/theme/widgets/liquid_bar.dart';
import '../../core/theme/widgets/sparkline.dart';
import '../../engine/parser/card_network.dart';
import '../cards/mini_card_art.dart';
import '../common/app_button.dart';
import '../common/app_check_mark.dart';
import '../common/motion.dart';
import '../common/premium_loading.dart';
import '../../core/utils/app_lucide_icons.dart';

/// DesignGalleryScreen — debug-only review surface for the Mali flagship
/// design system (docs/MALI_DESIGN_SYSTEM.md). Registered behind
/// `kDebugMode` in app_router.dart; unreachable in release builds.
///
/// Pure presentation: every value here is static demo/mock data. No
/// providers, no live financial data, no navigation into production flows.
/// Tokens resolve via [MaliTokens.of], so the gallery renders in whichever
/// theme (light/dark) is active.
class DesignGalleryScreen extends StatefulWidget {
  const DesignGalleryScreen({super.key});

  @override
  State<DesignGalleryScreen> createState() => _DesignGalleryScreenState();
}

class _DesignGalleryScreenState extends State<DesignGalleryScreen> {
  bool? _dark;

  @override
  Widget build(BuildContext context) {
    // Default to the ambient mode; the in-page toggle overrides it so the
    // whole gallery can be reviewed in both light and dark without leaving.
    final dark = _dark ?? Theme.of(context).brightness == Brightness.dark;
    return Theme(
      data: dark ? AppTheme.dark : AppTheme.light,
      child: Builder(
        builder: (context) {
          final t = MaliTokens.of(context);
          return MaliScreen(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Qirsh Design Gallery',
                              style: AppTypography.calmDisplay(
                                  t.textOnCanvasPrimary),
                            ),
                          ),
                          _ModeToggle(
                            dark: dark,
                            onChanged: (v) => setState(() => _dark = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Debug-only · Compact UI system · '
                        'docs/MALI_COMPACT_UI_SYSTEM_PLAN.md',
                        style: AppTypography.footnote(t.textOnCanvasMuted),
                      ),
                      const SizedBox(height: AppSpacing.s6),
                      const _CompactSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _ColorSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _TypographySection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _ShadowSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _BatchPrimitivesSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _RingSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _SparklineSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _ArchetypesSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _Archetypes2Section(),
                      const SizedBox(height: AppSpacing.s6),
                      const _CardSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _GlassSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _LiquidGlassSection(),
                      const SizedBox(height: AppSpacing.s6),
                      const _MotionSection(),
                      const SizedBox(height: AppSpacing.s9),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Light/dark toggle for reviewing every primitive in both modes in place.
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.dark, required this.onChanged});
  final bool dark;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return GestureDetector(
      onTap: () => onChanged(!dark),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: t.surfaceRaised,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: t.cardBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(dark ? AppLucideIcons.moon : AppLucideIcons.sun,
                size: 16, color: t.textOnCanvasSecondary),
            const SizedBox(width: 6),
            Text(dark ? 'داكن' : 'فاتح',
                style: AppTypography.caption(t.textOnCanvasSecondary)
                    .copyWith(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Compact UI system — the Phase-1 primitives at their new compact scale.
class _CompactSection extends StatelessWidget {
  const _CompactSection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return _GallerySection(
      title: 'Compact UI system',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // New role tokens.
          Text('sectionTitle 19',
              style: AppTypography.sectionTitle(t.textOnCanvasPrimary)),
          const SizedBox(height: 6),
          Text('cardTitle 16',
              style: AppTypography.cardTitle(t.textOnCanvasPrimary)),
          const SizedBox(height: AppSpacing.s4),
          // Page header (compact topInset + 24px title + 46px amount + strip).
          const MaliCard(
            padding: EdgeInsets.zero,
            child: CalmPageHeader(
              topInset: 16,
              useSafeAreaTop: false,
              // معرض مكوّنات: الهيدر داخل شريحة لوحده فمينفعش يمتد تحت.
              meltOverflow: 0,
              title: 'الميزانيات',
              subtitle: 'إجمالي المرصود هذا الشهر',
              amount: '4,820',
              currency: 'ج.م',
              metrics: [
                CalmMetric(label: 'آمنة', value: '5'),
                CalmMetric(label: 'اقتربت', value: '2'),
                CalmMetric(label: 'تجاوزت', value: '1'),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          // Chips.
          Row(
            children: [
              CalmChip(label: 'الكل', selected: true, onTap: () {}),
              const SizedBox(width: 8),
              CalmChip(label: 'مصروف', selected: false, onTap: () {}),
              const SizedBox(width: 8),
              CalmChip(label: 'دخل', selected: false, onTap: () {}),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          // Compact input + primary/ghost buttons (theme-driven heights).
          const TextField(
            decoration: InputDecoration(
              labelText: 'المبلغ',
              prefixIcon: Icon(AppLucideIcons.banknote),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('حفظ'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {},
                  child: const Text('إلغاء'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GallerySection extends StatelessWidget {
  const _GallerySection({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title),
        const SizedBox(height: AppSpacing.s4),
        child,
      ],
    );
  }
}

/// The 2026 UI batch primitives, side by side in both modes: the ink button,
/// LiquidBar, MiniCardArt, AppCheckMark and the row-shaped skeleton.
class _BatchPrimitivesSection extends StatelessWidget {
  const _BatchPrimitivesSection();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    return _GallerySection(
      title: 'Batch primitives — ink · liquid · mini cards',
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppPrimaryButton(label: 'متابعة'),
            const SizedBox(height: AppSpacing.s4),
            LiquidBar(value: 0.62, color: c.income),
            const SizedBox(height: AppSpacing.s2),
            const LiquidBar(value: null),
            const SizedBox(height: AppSpacing.s4),
            const Row(
              children: [
                MiniCardArt(
                    network: CardNetwork.mastercard, themeKey: 'graphite'),
                SizedBox(width: AppSpacing.s3),
                MiniCardArt(network: CardNetwork.visa, themeKey: 'navy'),
                SizedBox(width: AppSpacing.s3),
                MiniCardArt(network: CardNetwork.mada, themeKey: 'emerald'),
                Spacer(),
                AppCheckMark(selected: true),
                SizedBox(width: AppSpacing.s3),
                AppCheckMark(selected: false),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            Text('SkeletonRow',
                style: AppTypography.micro(t.textOnCanvasMuted)),
            // عيّنة ساكنة عمدًا: المعرض بيعرض الشكل، والنبض اللانهائي كان
            // يعلّق pumpAndSettle في اختبارات المعرض.
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: const SkeletonRow(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorSection extends StatelessWidget {
  const _ColorSection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final c = context.colors;
    final swatches = <(String, Color)>[
      ('canvas', t.canvas),
      ('surfaceRaised', t.surfaceRaised),
      ('surfaceFloating', t.surfaceFloating),
      ('surfaceGlassFill', t.surfaceGlassFill),
      ('accentStart', MaliTokens.accentStart),
      ('accentEnd', MaliTokens.accentEnd),
      ('income (AppColors)', c.income),
      ('expense (AppColors)', c.expense),
      ('warning (AppColors)', c.warning),
    ];
    return _GallerySection(
      title: 'Color',
      child: Wrap(
        spacing: AppSpacing.s3,
        runSpacing: AppSpacing.s3,
        children: [
          for (final (label, color) in swatches)
            Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: t.strokeSoft),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 72,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: AppTypography.micro(t.textOnCanvasSecondary),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _TypographySection extends StatelessWidget {
  const _TypographySection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final p = t.textOnCanvasPrimary;
    final s = t.textOnCanvasSecondary;
    return _GallerySection(
      title: 'Typography',
      child: MaliCard(
        style: MaliSurfaceStyle.raised,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Mixed Arabic + Latin + tabular-figure currency regression
            // cases (design doc §0.6).
            Text('48,250.00 ج.م', style: AppTypography.balanceHero(p)),
            const SizedBox(height: 4),
            Text('25,420 EGP', style: AppTypography.calmDisplay(p)),
            const SizedBox(height: 4),
            Text('−320.00 · نون تسوّق', style: AppTypography.body(s)),
            Divider(color: t.strokeSoft, height: 32),
            Text('calmDisplay 32', style: AppTypography.calmDisplay(p)),
            const SizedBox(height: 6),
            Text('calmTitle 22', style: AppTypography.calmTitle(p)),
            const SizedBox(height: 6),
            Text(
              'verdict 17 — وضعك مستقر هذا الشهر',
              style: AppTypography.verdict(s),
            ),
            const SizedBox(height: 6),
            Text('body 16', style: AppTypography.body(s)),
            const SizedBox(height: 6),
            Text('caption 12', style: AppTypography.caption(s)),
          ],
        ),
      ),
    );
  }
}

class _ShadowSection extends StatelessWidget {
  const _ShadowSection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return _GallerySection(
      title: 'Elevation',
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 72,
              decoration: BoxDecoration(
                color: t.surfaceFloating,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: t.cardBorder),
                boxShadow: AppShadows.floatSoft,
              ),
              alignment: Alignment.center,
              child: Text(
                'floatSoft',
                style: AppTypography.caption(t.textOnCanvasPrimary),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s4),
          Expanded(
            child: Container(
              height: 72,
              decoration: BoxDecoration(
                gradient: MaliTokens.accentGradient,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                boxShadow: AppShadows.heroGlow,
              ),
              alignment: Alignment.center,
              child: Text(
                'heroGlow',
                style: AppTypography.caption(Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingSection extends StatelessWidget {
  const _RingSection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    // Three columns share the row equally via Expanded — with a fixed ring
    // size + Row(spaceAround) this overflowed on real devices (content width
    // 342px on a standard iPhone, three 120px rings alone need 360px). A
    // smaller demo size + Expanded means it can no longer overflow, on any
    // screen width or text-scale setting.
    const demoRingSize = 84.0;
    final capStyle = TextStyle(
      color: t.textOnCanvasPrimary,
      fontWeight: FontWeight.w600,
    );
    return _GallerySection(
      title: 'RingProgress — Safe to Spend (concept, not wired)',
      child: Row(
        children: [
          Expanded(
            child: _RingDemo(
              ring: RingProgress(
                value: 0.62,
                size: demoRingSize,
                child: Text('62%', style: capStyle),
              ),
              label: 'مصروفك أعلى من المعتاد',
              labelColor: t.textOnCanvasSecondary,
            ),
          ),
          Expanded(
            child: _RingDemo(
              ring: const RingProgress(
                value: null,
                size: demoRingSize,
                child: Text('—'),
              ),
              label: 'بيانات غير كافية بعد',
              labelColor: t.textOnCanvasMuted,
            ),
          ),
          Expanded(
            child: _RingDemo(
              ring: RingProgress(
                value: 0.30,
                size: demoRingSize,
                color: context.colors.income,
                child: Text('آمن', style: capStyle),
              ),
              label: 'وضعك مستقر',
              labelColor: t.textOnCanvasSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// One ring + its plain-language label, sized to whatever width its
/// [Expanded] parent gives it — no fixed-width SizedBox, so it can't overflow
/// on a narrow device or with larger accessibility text scale.
class _RingDemo extends StatelessWidget {
  const _RingDemo({
    required this.ring,
    required this.label,
    required this.labelColor,
  });

  final Widget ring;
  final String label;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ring,
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.footnote(labelColor),
        ),
      ],
    );
  }
}

class _SparklineSection extends StatelessWidget {
  const _SparklineSection();

  @override
  Widget build(BuildContext context) {
    return const _GallerySection(
      title: 'Sparkline',
      child: MaliCard(
        style: MaliSurfaceStyle.raised,
        child: Sparkline(
          values: [12, 18, 9, 22, 15, 30, 26, 34],
        ),
      ),
    );
  }
}

class _ArchetypesSection extends StatelessWidget {
  const _ArchetypesSection();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _GallerySection(
      title: 'Archetypes (concept, not wired)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PulseRow(metrics: [
            const PulseMetric(label: 'دخل اليوم', value: '+12,500'),
            PulseMetric(
                label: 'مصروف اليوم', value: '−3,240', color: c.expense),
            PulseMetric(label: 'الصافي', value: '+9,260', color: c.income),
          ]),
          const SizedBox(height: AppSpacing.s3),
          const AttentionCard(
            icon: AppLucideIcons.alertTriangle,
            title: '٣ عمليات في انتظار مراجعتك',
            subtitle: 'راجعها عشان أرصدتك تفضل مظبوطة',
          ),
          const SizedBox(height: AppSpacing.s3),
          const InsightCard(
            label: 'مساعد مالي',
            message:
                'مصروفك على المطاعم أقل بـ18% عن الشهر اللي فات. لو كمّلت كده '
                'هتوفّر 640 ريال آخر الشهر.',
            ctaText: 'التفاصيل',
          ),
          const SizedBox(height: AppSpacing.s3),
          MaliCard(
            style: MaliSurfaceStyle.floating,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                LedgerRow(
                  icon: AppLucideIcons.shoppingBag,
                  iconTint: c.expense,
                  title: 'نون · تسوّق',
                  subtitle: '2:14 م · تسوق',
                  amount: '−320.00',
                ),
                LedgerRow(
                  icon: AppLucideIcons.coffee,
                  iconTint: c.warning,
                  title: 'ستاربكس',
                  subtitle: '8:10 ص · كافيهات',
                  amount: '−27.50',
                  isPending: true,
                ),
                LedgerRow(
                  icon: AppLucideIcons.arrowDownLeft,
                  iconTint: c.income,
                  title: 'تحويل وارد',
                  subtitle: '1:05 م · تحويلات',
                  amount: '+1,500.00',
                  amountColor: c.income,
                  isAi: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Archetypes2Section extends StatelessWidget {
  const _Archetypes2Section();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final c = context.colors;
    return _GallerySection(
      title: 'Archetypes II — charts & rows',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const BalanceStatement(
            label: 'الرصيد الكلي',
            amount: '48,250.00',
            currency: 'ريال',
            trendText: '2.4% هذا الشهر',
            trendIcon: AppLucideIcons.trendingUp,
          ),
          const SizedBox(height: AppSpacing.s5),
          MaliCard(
            style: MaliSurfaceStyle.floating,
            child: Row(
              children: [
                const ScoreGauge(score: 78, caption: 'من 100'),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('درجة قرش',
                          style:
                              AppTypography.caption(t.textOnCanvasSecondary)),
                      const SizedBox(height: 4),
                      Text('جيد · وضعك المالي متماسك',
                          style:
                              AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          MaliCard(
            style: MaliSurfaceStyle.floating,
            child: Row(
              children: [
                DonutChart(
                  segments: [
                    const DonutSegment(
                        value: 34, color: MaliTokens.accentStart),
                    const DonutSegment(value: 22, color: Color(0xFF7C6BF0)),
                    DonutSegment(value: 15, color: c.income),
                    DonutSegment(value: 12, color: c.warning),
                  ],
                  center: Text('8,430',
                      style: AppTypography.subhead(t.textOnCanvasPrimary)),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Legend(
                          color: MaliTokens.accentStart,
                          name: 'مطاعم',
                          pc: '%34'),
                      const _Legend(
                          color: Color(0xFF7C6BF0), name: 'تسوق', pc: '%22'),
                      _Legend(color: c.income, name: 'مواصلات', pc: '%15'),
                      _Legend(color: c.warning, name: 'فواتير', pc: '%12'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          MaliCard(
            style: MaliSurfaceStyle.floating,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                MerchantBar(
                    name: 'نون',
                    amount: '1,240',
                    fraction: 1.0,
                    meta: '8 عمليات',
                    markColor: c.textPrimary),
                const MerchantBar(
                    name: 'كارفور',
                    amount: '860',
                    fraction: 0.7,
                    meta: '5 عمليات',
                    markColor: MaliTokens.accentStart),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          const BudgetRingRail(rings: [
            BudgetRing(value: 0.70, name: 'مطاعم', sub: '700 / 1000'),
            BudgetRing(value: 0.88, name: 'تسوّق', sub: '1,760 / 2,000'),
            BudgetRing(value: 0.30, name: 'مواصلات', sub: '150 / 500'),
          ]),
          const SizedBox(height: AppSpacing.s3),
          AccountCard(
            icon: AppLucideIcons.landmark,
            tint: MaliTokens.accentStart,
            name: 'بنك مصر',
            subtitle: 'بنك · ريال (SAR)',
            balance: '42,180',
            balanceCurrency: 'ريال',
            isDefault: true,
            onTap: () {},
          ),
          const SizedBox(height: AppSpacing.s3),
          SegmentedControl<int>(
            value: 0,
            accent: true,
            onChanged: (_) {},
            options: const [
              SegmentOption(
                  value: 0, label: 'مصروف', icon: AppLucideIcons.minus),
              SegmentOption(value: 1, label: 'دخل', icon: AppLucideIcons.plus),
              SegmentOption(
                  value: 2,
                  label: 'تحويل',
                  icon: AppLucideIcons.arrowLeftRight),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          SheetField(
            icon: AppLucideIcons.wallet,
            label: 'الحساب',
            value: 'بنك مصر · ريال',
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.name, required this.pc});
  final Color color;
  final String name;
  final String pc;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.subhead(t.textOnCanvasPrimary)),
          ),
          Text(pc, style: AppTypography.subhead(t.textOnCanvasSecondary)),
        ],
      ),
    );
  }
}

class _CardSection extends StatelessWidget {
  const _CardSection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    Widget label(String s) => Text(
          s,
          style: AppTypography.subhead(t.textOnCanvasPrimary),
        );
    return _GallerySection(
      title: 'MaliCard variants',
      child: Column(
        children: [
          MaliCard(style: MaliSurfaceStyle.raised, child: label('raised')),
          const SizedBox(height: AppSpacing.s3),
          MaliCard(style: MaliSurfaceStyle.floating, child: label('floating')),
          const SizedBox(height: AppSpacing.s3),
          MaliCard(style: MaliSurfaceStyle.glass, child: label('glass')),
          const SizedBox(height: AppSpacing.s3),
          MaliCard(
            style: MaliSurfaceStyle.accent,
            child: Text(
              'accent',
              style: AppTypography.subhead(Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassSection extends StatelessWidget {
  const _GlassSection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return _GallerySection(
      title: 'GlassSurface',
      child: GlassSurface(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          'الحساب الجاري · ج.م',
          style: AppTypography.subhead(t.textOnCanvasPrimary),
        ),
      ),
    );
  }
}

/// MaliGlass pilot — every variant/tier over a vivid demo backdrop so the
/// blur, rim, sheen (and the Tier 3 refraction prototype) are actually
/// visible. Review with the mode toggle for light + dark.
class _LiquidGlassSection extends StatelessWidget {
  const _LiquidGlassSection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final shaderOk = ui.ImageFilter.isShaderFilterSupported;
    return _GallerySection(
      title: 'MaliGlass (Liquid Glass pilot)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GlassDemo(
            label: 'pill — Tier 1 (static)',
            child: MaliGlass(
              variant: MaliGlassVariant.pill,
              child: Text('الحساب الجاري',
                  style: AppTypography.subhead(t.textOnCanvasPrimary)),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'pill — Tier 2 (interactive: press me)',
            child: MaliGlass(
              variant: MaliGlassVariant.pill,
              onTap: () {},
              child: Text('آخر ٣٠ يوم',
                  style: AppTypography.subhead(t.textOnCanvasPrimary)),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'card — Tier 1 (static)',
            child: MaliGlass(
              variant: MaliGlassVariant.card,
              child: Text('بطاقة زجاجية — المحتوى يبقى واضحًا',
                  style: AppTypography.subhead(t.textOnCanvasPrimary)),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'navigation — Tier 1 container (tabs supply Tier 2)',
            child: MaliGlass(
              variant: MaliGlassVariant.navigation,
              child: SizedBox(
                height: AppSpacing.navBarHeight - 12,
                child: Row(
                  children: [
                    for (final icon in const [
                      AppLucideIcons.home,
                      AppLucideIcons.receipt,
                      AppLucideIcons.pieChart,
                    ])
                      Expanded(
                        child:
                            Icon(icon, size: 20, color: t.textOnCanvasPrimary),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'headerAction — on-accent circle, rim + press, no blur',
            child: MaliGlass(
              variant: MaliGlassVariant.headerAction,
              onTap: () {},
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child:
                      Icon(AppLucideIcons.plus, color: Colors.white, size: 24),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'sheet — near-opaque body, translucent top band',
            child: SizedBox(
              height: 140,
              width: double.infinity,
              child: MaliGlass(
                variant: MaliGlassVariant.sheet,
                child: Column(
                  children: [
                    const SizedBox(height: AppSpacing.s3),
                    Container(
                      width: 40,
                      height: 5,
                      decoration: BoxDecoration(
                        color: t.textOnCanvasMuted.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Text('عملية جديدة',
                        style: AppTypography.cardTitle(t.textOnCanvasPrimary)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'reduce-motion — press: static state, no scale',
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: MaliGlass(
                  variant: MaliGlassVariant.pill,
                  onTap: () {},
                  child: Text('بدون حركة',
                      style: AppTypography.subhead(t.textOnCanvasPrimary)),
                ),
              ),
            ),
          ),
          // ── SPIKE (gallery-only): liquid_glass_renderer A/B/C vs MaliGlass.
          // Same stage, same child, same 28 radius, both themes via the
          // gallery toggle. Not used on any production surface.
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'SPIKE A — MaliGlass card (custom)',
            child: MaliGlass(
              variant: MaliGlassVariant.card,
              child: Text('بطاقة زجاجية — MaliGlass',
                  style: AppTypography.subhead(t.textOnCanvasPrimary)),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'SPIKE B — liquid_glass_renderer '
                '(${ui.ImageFilter.isShaderFilterSupported ? 'live' : 'Impeller only — unsupported here'})',
            child: ui.ImageFilter.isShaderFilterSupported
                ? lgr.LiquidGlass.withOwnLayer(
                    shape:
                        const lgr.LiquidRoundedSuperellipse(borderRadius: 28),
                    settings: const lgr.LiquidGlassSettings(
                      thickness: 24,
                      blur: 6,
                      saturation: 1.4,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.cardPadding),
                      child: Text('بطاقة زجاجية — liquid_glass_renderer',
                          style: AppTypography.subhead(t.textOnCanvasPrimary)),
                    ),
                  )
                : Text('يتطلب Impeller — هنا يعمل التراجع لدينا فقط',
                    style: AppTypography.caption(t.textOnCanvasMuted)),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'SPIKE C — FakeGlass (تراجع الحزمة الخفيف)',
            child: lgr.FakeGlass(
              shape: const lgr.LiquidRoundedSuperellipse(borderRadius: 28),
              settings: const lgr.LiquidGlassSettings(
                thickness: 24,
                blur: 6,
                saturation: 1.4,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.cardPadding),
                child: Text('بطاقة زجاجية — FakeGlass',
                    style: AppTypography.subhead(t.textOnCanvasPrimary)),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'SPIKE D — MaliGlass(advancedRefraction) عبر الـ adapter',
            child: MaliGlass(
              variant: MaliGlassVariant.card,
              advancedRefraction: true,
              child: Text('بطاقة زجاجية — MaliGlass advanced',
                  style: AppTypography.subhead(t.textOnCanvasPrimary)),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'high-contrast — opaque fallback, no blur',
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(highContrast: true),
                child: MaliGlass(
                  variant: MaliGlassVariant.card,
                  child: Text('تباين عالٍ — خلفية معتمة',
                      style: AppTypography.subhead(t.textOnCanvasPrimary)),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          _GlassDemo(
            label: 'EXPERIMENTAL / REFRACTIVE — Tier 3 prototype '
                '(${shaderOk ? 'shader filters: supported' : 'unsupported here → Tier 2 fallback'})',
            child: MaliGlass(
              variant: MaliGlassVariant.card,
              refractive: true,
              onTap: () {},
              child: Text('انكسار حافّي + انزياح لوني طفيف',
                  style: AppTypography.subhead(t.textOnCanvasPrimary)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A vivid backdrop (accent gradient + off-accent dots + a sample amount) so
/// glass demos have real content to blur/refract behind them.
class _GlassDemo extends StatelessWidget {
  const _GlassDemo({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTypography.caption(t.textOnCanvasMuted)),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration:
                      BoxDecoration(gradient: MaliTokens.accentGradient),
                ),
              ),
              Positioned(
                top: -18,
                left: 24,
                child: _dot(const Color(0xFFFBC926), 64),
              ),
              Positioned(
                bottom: -14,
                right: 36,
                child: _dot(const Color(0xFF22C55E), 48),
              ),
              Positioned(
                top: 10,
                right: 14,
                child: Text(
                  '١٢٬٣٤٥٫٦٧ ر.س',
                  style: AppTypography.amountSmall(Colors.white),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s6),
                child: child,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static Widget _dot(Color color, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );
}

class _MotionSection extends StatelessWidget {
  const _MotionSection();

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return _GallerySection(
      title: 'Motion (reused primitives)',
      child: PremiumMotion(
        child: MaliCard(
          style: MaliSurfaceStyle.floating,
          child: AnimatedAmountText(
            amount: 12340,
            color: t.textOnCanvasPrimary,
            suffix: ' ج.م',
            style: AppTypography.balanceHero(t.textOnCanvasPrimary),
          ),
        ),
      ),
    );
  }
}
