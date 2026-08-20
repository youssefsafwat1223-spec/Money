// Font-candidate specimen board — renders the same Qirsh-style block in the
// current font vs the free (OFL) alternatives closest to Graphik Arabic, so
// the choice is made with eyes. Gated by SHOT_DIR like the batch board.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';

final String? _shotDir = Platform.environment['SHOT_DIR'];
const _dlDir = '/Users/youssef/.claude/jobs/5bb57506/tmp/fonts';

Future<void> _loadAsset(FontLoader loader, String asset) async =>
    loader.addFont(rootBundle.load(asset));

Future<void> _loadFile(FontLoader loader, String path) async {
  final bytes = await File(path).readAsBytes();
  loader.addFont(Future.value(ByteData.view(bytes.buffer)));
}

Future<void> _loadFonts() async {
  final alex = FontLoader('Alexandria');
  for (final a in [
    'assets/fonts/Alexandria-Regular.ttf',
    'assets/fonts/Alexandria-Medium.ttf',
    'assets/fonts/Alexandria-SemiBold.ttf',
    'assets/fonts/Alexandria-Bold.ttf',
  ]) {
    await _loadAsset(alex, a);
  }
  await alex.load();

  final plex = FontLoader('IBMPlexSansArabic');
  for (final a in [
    'assets/fonts/IBMPlexSansArabic-Regular.ttf',
    'assets/fonts/IBMPlexSansArabic-Medium.ttf',
    'assets/fonts/IBMPlexSansArabic-SemiBold.ttf',
    'assets/fonts/IBMPlexSansArabic-Bold.ttf',
  ]) {
    await _loadAsset(plex, a);
  }
  await plex.load();

  final tajawal = FontLoader('Tajawal');
  for (final f in [
    'Tajawal-Regular.ttf',
    'Tajawal-Medium.ttf',
    'Tajawal-Bold.ttf',
  ]) {
    await _loadFile(tajawal, '$_dlDir/$f');
  }
  await tajawal.load();

  final almarai = FontLoader('Almarai');
  for (final f in ['Almarai-Regular.ttf', 'Almarai-Bold.ttf']) {
    await _loadFile(almarai, '$_dlDir/$f');
  }
  await almarai.load();
}

class _Specimen extends StatelessWidget {
  const _Specimen({required this.family, required this.title});
  final String family;
  final String title;

  TextStyle _s(double size, FontWeight w, {double ls = 0}) => TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: w,
        letterSpacing: ls,
        height: 1.35,
        color: const Color(0xFF0F172A),
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
              color: Color(0x140D1E4B), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style: TextStyle(
                  fontFamily: family,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF2E6BFF))),
          const SizedBox(height: 10),
          Text('12,400.00 جنيه', style: _s(34, FontWeight.w700, ls: -0.5)),
          const SizedBox(height: 6),
          Text('الأهداف — رحلة الصيف 62%', style: _s(18, FontWeight.w600)),
          const SizedBox(height: 4),
          Text('تم توفير 12,400 من 20,000 · باقي 7,600 جنيه للوصول',
              style: _s(14, FontWeight.w400)),
          const SizedBox(height: 4),
          Text('عمليات اليوم: قهوة 18.50 · مواصلات 42 · Netflix 165.00',
              style: _s(13, FontWeight.w500)),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture font specimen board', (tester) async {
    if (_shotDir == null) return;
    tester.view.physicalSize = const Size(780, 1760);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.runAsync(_loadFonts);

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        debugShowCheckedModeBanner: false,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: RepaintBoundary(
            key: key,
            child: Scaffold(
              backgroundColor: const Color(0xFFF4F6FB),
              body: ListView(
                padding: const EdgeInsets.all(20),
                children: const [
                  _Specimen(family: 'Alexandria', title: 'Alexandria — الحالي'),
                  _Specimen(
                      family: 'IBMPlexSansArabic',
                      title:
                          'IBM Plex Sans Arabic — متشحن أصلًا · أوزان كاملة'),
                  _Specimen(
                      family: 'Tajawal',
                      title: 'Tajawal — هندسي منخفض التباين · بلا وزن 600'),
                  _Specimen(
                      family: 'Almarai',
                      title: 'Almarai — نظيف حديث · أوزان 400/700 فقط'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_shotDir/font_specimens.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      // ignore: avoid_print
      print('WROTE ${file.path}');
    });
  });
}
