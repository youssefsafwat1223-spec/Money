// One-off visual capture harness for the 2026 UI batch — renders the new
// primitives and adoption surfaces in light + dark and writes PNGs to
// SHOT_DIR (skipped entirely when the env var is absent, so CI never runs it).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_shadows.dart';
import 'package:money_companion/core/theme/app_spacing.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/app_typography.dart';
import 'package:money_companion/core/theme/mali_tokens.dart';
import 'package:money_companion/core/theme/widgets/liquid_bar.dart';
import 'package:money_companion/core/theme/widgets/mali_card.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/mini_card_art.dart';
import 'package:money_companion/core/theme/widgets/calm_chip.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';
import 'package:money_companion/core/theme/widgets/segmented_control.dart';
import 'package:money_companion/features/common/app_button.dart';
import 'package:money_companion/features/common/app_check_mark.dart';
import 'package:money_companion/features/common/app_pill_tab_bar.dart';
import 'package:money_companion/features/common/premium_loading.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';

final String? _shotDir = Platform.environment['SHOT_DIR'];

Future<void> _loadFonts() async {
  for (final (family, assets) in [
    (
      'Vazirmatn',
      [
        'assets/fonts/Vazirmatn-Regular.ttf',
        'assets/fonts/Vazirmatn-Medium.ttf',
        'assets/fonts/Vazirmatn-SemiBold.ttf',
        'assets/fonts/Vazirmatn-Bold.ttf',
      ]
    ),
    (
      'Alexandria',
      [
        'assets/fonts/Alexandria-Regular.ttf',
        'assets/fonts/Alexandria-Medium.ttf',
        'assets/fonts/Alexandria-SemiBold.ttf',
        'assets/fonts/Alexandria-Bold.ttf',
      ]
    ),
  ]) {
    final loader = FontLoader(family);
    for (final asset in assets) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }
  // Material icon glyphs render as boxes in the test env unless the icon font
  // is loaded from the SDK cache explicitly.
  final root = Platform.environment['FLUTTER_ROOT'];
  final iconFont = root == null
      ? null
      : File(
          '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (iconFont != null && iconFont.existsSync()) {
    final bytes = await iconFont.readAsBytes();
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    Widget label(String s) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Text(s, style: AppTypography.label(t.textOnCanvasMuted)),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          label('AppPrimaryButton — ink'),
          AppPrimaryButton(label: 'متابعة', onTap: () {}),
          const SizedBox(height: 10),
          const AppPrimaryButton(label: 'حفظ', disabled: true),
          label('الهدف — LiquidBar'),
          MaliCard(
            style: MaliSurfaceStyle.floating,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.income.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child:
                          Icon(Icons.flag_rounded, color: c.income, size: 19),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text('رحلة الصيف',
                          style:
                              AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: c.income.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('62%', style: AppTypography.label(c.income)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                LiquidBar(value: 0.62, color: c.income, animate: false),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Expanded(
                      child: Text('تم توفير 12,400.00',
                          style:
                              AppTypography.caption(t.textOnCanvasSecondary)),
                    ),
                    Text('باقي 7,600.00',
                        style: AppTypography.caption(t.textOnCanvasSecondary)),
                  ],
                ),
              ],
            ),
          ),
          label('MiniCardArt + AppCheckMark'),
          const Row(
            children: [
              MiniCardArt(
                  network: CardNetwork.mastercard, themeKey: 'graphite'),
              SizedBox(width: 12),
              MiniCardArt(network: CardNetwork.visa, themeKey: 'navy'),
              SizedBox(width: 12),
              MiniCardArt(network: CardNetwork.mada, themeKey: 'emerald'),
              Spacer(),
              AppCheckMark(selected: true),
              SizedBox(width: 12),
              AppCheckMark(selected: false),
            ],
          ),
          label('SkeletonRow'),
          const SkeletonRow(),
          const SkeletonRow(),
          label('FAB — ink'),
          Align(
            alignment: AlignmentDirectional.bottomStart,
            child: Material(
              color: c.ink,
              shape: const CircleBorder(),
              elevation: 6,
              shadowColor: Colors.black.withValues(alpha: 0.35),
              child: SizedBox(
                width: 56,
                height: 56,
                child: Icon(AppLucideIcons.plus, color: c.onInk, size: 26),
              ),
            ),
          ),
          label('Switch / dialog theming'),
          Row(
            children: [
              Switch(value: true, onChanged: (_) {}),
              Switch(value: false, onChanged: (_) {}),
              const SizedBox(width: 12),
              Radio<int>(value: 1, groupValue: 1, onChanged: (_) {}),
              Radio<int>(value: 2, groupValue: 1, onChanged: (_) {}),
            ],
          ),
          label('AppPillTabBar — ink selected'),
          AppPillTabBar(
            tabs: const ['الاشتراكات (4)', 'الأقساط (2)'],
            selectedIndex: 0,
            onSelected: (_) {},
          ),
          label('CalmChip + SegmentedControl accent'),
          Row(
            children: [
              CalmChip(label: 'الكل', selected: true, onTap: () {}),
              const SizedBox(width: 8),
              CalmChip(label: 'مصروف', selected: false, onTap: () {}),
              const SizedBox(width: 8),
              CalmChip(label: 'دخل', selected: false, onTap: () {}),
            ],
          ),
          const SizedBox(height: 10),
          SegmentedControl<int>(
            accent: true,
            value: 0,
            onChanged: (_) {},
            options: const [
              SegmentOption(value: 0, label: 'مصروف'),
              SegmentOption(value: 1, label: 'دخل'),
            ],
          ),
          label('CalmPageHeader — melted into bg'),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Column(
              children: [
                const CalmPageHeader(
                  title: 'الأهداف',
                  subtitle: 'إجمالي المدخر لكل أحلامك',
                  useSafeAreaTop: false,
                  topInset: 20,
                  amount: '12,400.00',
                  currency: 'جنيه',
                  metrics: [
                    CalmMetric(label: 'أهداف نشطة', value: '3'),
                    CalmMetric(label: 'نسبة التقدم', value: '62%'),
                    CalmMetric(label: 'المستهدف', value: '20,000'),
                  ],
                ),
                Container(
                  color: c.bg,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: const SkeletonRow(),
                ),
              ],
            ),
          ),
          label('Bottom bar — floating'),
          const _NavBarPreview(),
        ],
      ),
    );
  }
}

/// نسخة معاينة من `_BottomNavBar` (اللي في app_shell خاص فمينفعش يتنادى من
/// التست) — لازم تفضل مطابقة ليه في الشكل: عايم بحواف 30 وظل وحد رفيع.
class _NavBarPreview extends StatelessWidget {
  const _NavBarPreview();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.s4),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? c.surface
              : Colors.white,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: c.divider),
          boxShadow: AppShadows.float,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          textDirection: TextDirection.ltr,
          children: [
            for (final (icon, text, on) in [
              (Icons.more_horiz_rounded, 'المزيد', false),
              (AppLucideIcons.barChart3, 'التحليلات', false),
              (AppLucideIcons.home, 'الرئيسية', true),
              (Icons.pie_chart_outline_rounded, 'الميزانيات', false),
              (AppLucideIcons.receipt, 'العمليات', false),
            ])
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon,
                        size: 20, color: on ? c.textPrimary : c.textMuted),
                    const SizedBox(height: 3),
                    Text(text,
                        style: AppTypography.caption(
                                on ? c.textPrimary : c.textMuted)
                            .copyWith(
                                fontSize: 10,
                                fontWeight:
                                    on ? FontWeight.w800 : FontWeight.w600)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _capture(WidgetTester tester, ThemeData theme, String name) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: RepaintBoundary(
          key: key,
          child: const Scaffold(body: _Board()),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_shotDir/$name.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('WROTE ${file.path} (${bytes.lengthInBytes} bytes)');
  });
}

/// معاينة بمقاس موبايل حقيقي: الهيدر بنص الشاشة + محتوى + البار العايم
/// والمسافة اللي تحته — عشان الشكل النهائي يتحكم عليه بالعين.
class _PhonePreview extends StatelessWidget {
  const _PhonePreview();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      extendBody: true,
      backgroundColor: c.bg,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          const CalmPageHeader(
            title: 'الأهداف',
            subtitle: 'إجمالي المدخر لكل أحلامك',
            amount: '12,400.00',
            currency: 'جنيه',
            useSafeAreaTop: false,
            metrics: [
              CalmMetric(label: 'أهداف نشطة', value: '3'),
              CalmMetric(label: 'نسبة التقدم', value: '62%'),
              CalmMetric(label: 'المستهدف', value: '20,000'),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
            child: Column(
              children: [
                for (final (name, pct) in [
                  ('رحلة الصيف', 0.62),
                  ('لابتوب جديد', 0.35),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: MaliCard(
                      style: MaliSurfaceStyle.floating,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: AppTypography.cardTitle(c.textPrimary)),
                          const SizedBox(height: 10),
                          LiquidBar(value: pct, color: c.income),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: const _NavBarPreview(),
    );
  }
}

/// نفس تركيبة صفحات الميزانيات/الاشتراكات/التقارير: NestedScrollView والهيدر
/// في الـ headerSliverBuilder والمحتوى في body منفصل — عشان نتأكد إن امتداد
/// الأزرق بيتصرف زي صفحات الـ ListView العادية.
class _NestedPreview extends StatelessWidget {
  const _NestedPreview();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      extendBody: true,
      backgroundColor: c.bg,
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          const SliverToBoxAdapter(
            child: Column(
              children: [
                CalmPageHeader(
                  meltOverflow: 0,
                  title: 'الميزانيات',
                  subtitle: 'المصروف من حدود الشهر',
                  amount: '8,200.00',
                  currency: 'جنيه',
                  useSafeAreaTop: false,
                  metrics: [
                    CalmMetric(label: 'آمنة', value: '4'),
                    CalmMetric(label: 'تحذير', value: '1'),
                    CalmMetric(label: 'تجاوزت', value: '0'),
                  ],
                ),
                SizedBox(height: AppSpacing.s2),
              ],
            ),
          ),
        ],
        body: MeltTail(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, 120),
            children: [
              for (final name in ['أكل ومشروبات', 'مواصلات'])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: MaliCard(
                    style: MaliSurfaceStyle.floating,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: AppTypography.cardTitle(c.textPrimary)),
                        const SizedBox(height: 10),
                        LiquidBar(value: 0.48, color: c.income),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: const _NavBarPreview(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture batch board light+dark', (tester) async {
    if (_shotDir == null) return;
    tester.view.physicalSize = const Size(780, 4400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.runAsync(_loadFonts);
    await _capture(tester, AppTheme.light, 'batch_light');
    await _capture(tester, AppTheme.dark, 'batch_dark');
  });

  testWidgets('capture phone preview light+dark', (tester) async {
    if (_shotDir == null) return;
    tester.view.physicalSize = const Size(780, 1688); // 390×844 @2x
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.runAsync(_loadFonts);
    for (final (theme, name, page) in [
      (AppTheme.light, 'phone_light', const _PhonePreview()),
      (AppTheme.dark, 'phone_dark', const _PhonePreview()),
      (AppTheme.light, 'nested_light', const _NestedPreview()),
      (AppTheme.dark, 'nested_dark', const _NestedPreview()),
    ]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          debugShowCheckedModeBanner: false,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: RepaintBoundary(key: key, child: page),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$_shotDir/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        // ignore: avoid_print
        print('WROTE $name.png');
      });
    }
  });
}
