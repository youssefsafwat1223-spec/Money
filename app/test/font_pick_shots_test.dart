// Font picker board — the app's REAL text hierarchy (hero amount, ledger row,
// settings row) rendered in every bundled/candidate family, so the choice is
// made by eye on actual UI copy instead of a specimen sheet. SHOT_DIR-gated.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _shotDir = Platform.environment['SHOT_DIR'];
const _dl = '/Users/youssef/.claude/jobs/5bb57506/tmp/fonts';

const _candidates = <String, List<String>>{
  'Alyamama': [
    'assets/fonts/Alyamama-Regular.ttf',
    'assets/fonts/Alyamama-SemiBold.ttf',
    'assets/fonts/Alyamama-Bold.ttf',
  ],
  'Vazirmatn': [
    'assets/fonts/Vazirmatn-Regular.ttf',
    'assets/fonts/Vazirmatn-SemiBold.ttf',
    'assets/fonts/Vazirmatn-Bold.ttf',
  ],
  'IBMPlexSansArabic': [
    'assets/fonts/IBMPlexSansArabic-Regular.ttf',
    'assets/fonts/IBMPlexSansArabic-SemiBold.ttf',
    'assets/fonts/IBMPlexSansArabic-Bold.ttf',
  ],
  'Alexandria': [
    'assets/fonts/Alexandria-Regular.ttf',
    'assets/fonts/Alexandria-SemiBold.ttf',
    'assets/fonts/Alexandria-Bold.ttf',
  ],
};

const _external = <String, List<String>>{
  'Tajawal': [
    '$_dl/Tajawal-Regular.ttf',
    '$_dl/Tajawal-Medium.ttf',
    '$_dl/Tajawal-Bold.ttf',
  ],
  'Almarai': ['$_dl/Almarai-Regular.ttf', '$_dl/Almarai-Bold.ttf'],
  'ReadexPro': ['$_dl/ReadexPro[HEXP,wght].ttf'],
  'NotoSansArabic': ['$_dl/NotoSansArabic[wdth,wght].ttf'],
};

Future<void> _loadFonts() async {
  for (final e in {..._candidates, ..._external}.entries) {
    if (!File(e.value.first).existsSync()) continue;
    final l = FontLoader(e.key);
    for (final p in e.value) {
      final b = await File(p).readAsBytes();
      l.addFont(Future.value(ByteData.view(b.buffer)));
    }
    await l.load();
  }
}

/// One family rendered over the app's real hierarchy.
class _Sample extends StatelessWidget {
  const _Sample(this.family);
  final String family;

  TextStyle _s(double size, FontWeight w, Color c, {double h = 1.3}) =>
      TextStyle(
          fontFamily: family,
          fontSize: size,
          fontWeight: w,
          height: h,
          color: c);

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF111827);
    const muted = Color(0xFF7C879A);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDDE2EC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Blue hero strip — the header amount.
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            decoration: const BoxDecoration(
              color: Color(0xFF021B79),
              borderRadius: BorderRadius.vertical(top: Radius.circular(17)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(family,
                    style: TextStyle(
                        fontFamily: family,
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.55),
                        letterSpacing: 1.2)),
                const SizedBox(height: 6),
                Text('إجمالي مصروفات الفترة',
                    style: _s(12, FontWeight.w400,
                        Colors.white.withValues(alpha: 0.72))),
                const SizedBox(height: 2),
                Text('18,147.59 جنيه',
                    style: _s(34, FontWeight.w700, Colors.white, h: 1.15)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('نتفليكس', style: _s(16, FontWeight.w700, ink)),
                          const SizedBox(height: 3),
                          Text('اشتراكات · شهري · متأخر ٢١ يوم',
                              style: _s(12, FontWeight.w400, muted)),
                        ],
                      ),
                    ),
                    Text('−200.00', style: _s(16, FontWeight.w700, ink)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('العملة الأساسية',
                              style: _s(14, FontWeight.w600, ink)),
                          const SizedBox(height: 3),
                          Text('الجنيه المصري · EGP',
                              style: _s(12, FontWeight.w400, muted)),
                        ],
                      ),
                    ),
                    Text('الميزانيات', style: _s(13, FontWeight.w700, ink)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  testWidgets('font picker board', (tester) async {
    if (_shotDir == null) return;
    await tester.runAsync(_loadFonts);
    final families = [
      for (final e in {..._candidates, ..._external}.entries)
        if (File(e.value.first).existsSync()) e.key,
    ];

    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
          key: key,
          // Material ancestor — otherwise flutter_test paints the debug
          // yellow underline under every Text and ruins the comparison.
          child: Material(
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Container(
                color: const Color(0xFFF4F6FB),
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child:
                      Column(children: [for (final f in families) _Sample(f)]),
                ),
              ),
            ),
          )),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_shotDir/font_picker.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
