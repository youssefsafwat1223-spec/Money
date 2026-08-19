// Graphik-Arabic match board — the actual Behance reference sample on top,
// then every free (OFL) neutral-grotesque Arabic candidate rendering the SAME
// phrase, so "closest to the reference" is judged by eye. SHOT_DIR-gated.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _shotDir = Platform.environment['SHOT_DIR'];
const _dl = '/Users/youssef/.claude/jobs/5bb57506/tmp/fonts';
const _ref = '/Users/youssef/.claude/jobs/5bb57506/tmp/graphik_ref.png';

Future<void> _file(FontLoader l, String p) async {
  final b = await File(p).readAsBytes();
  l.addFont(Future.value(ByteData.view(b.buffer)));
}

Future<void> _asset(FontLoader l, String a) async =>
    l.addFont(rootBundle.load(a));

Future<void> _loadFonts() async {
  final specs = <String, List<String>>{
    'Mada': ['$_dl/Mada[wght].ttf'],
    'Vazirmatn': ['$_dl/Vazirmatn[wght].ttf'],
    'NotoSansArabic': ['$_dl/NotoSansArabic[wdth,wght].ttf'],
    'ReadexPro': ['$_dl/ReadexPro[HEXP,wght].ttf'],
    'Zain': ['$_dl/Zain-Regular.ttf', '$_dl/Zain-Bold.ttf'],
    'Tajawal': [
      '$_dl/Tajawal-Regular.ttf',
      '$_dl/Tajawal-Medium.ttf',
      '$_dl/Tajawal-Bold.ttf',
    ],
    'Almarai': ['$_dl/Almarai-Regular.ttf', '$_dl/Almarai-Bold.ttf'],
  };
  for (final e in specs.entries) {
    final l = FontLoader(e.key);
    for (final p in e.value) {
      await _file(l, p);
    }
    await l.load();
  }
  final plex = FontLoader('IBMPlexSansArabic');
  await _asset(plex, 'assets/fonts/IBMPlexSansArabic-SemiBold.ttf');
  await plex.load();
}

class _Row extends StatelessWidget {
  const _Row(this.family, this.label);
  final String family;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1418C8).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label,
              style: const TextStyle(
                  fontFamily: 'IBMPlexSansArabic',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xB3FFFFFF))),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              'أفضـل الخطــوط العربية',
              style: TextStyle(
                fontFamily: family,
                fontSize: 52,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.15,
                fontVariations: const [ui.FontVariation('wght', 600)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture graphik match board', (tester) async {
    if (_shotDir == null) return;
    tester.view.physicalSize = const Size(820, 2350);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.runAsync(_loadFonts);
    // Decode the reference PNG to a ui.Image inside runAsync — Image.memory's
    // async decode never completes under fake-async, rendering blank.
    final ui.Image refImage = (await tester.runAsync(() async {
      final codec =
          await ui.instantiateImageCodec(File(_ref).readAsBytesSync());
      return (await codec.getNextFrame()).image;
    }))!;

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: RepaintBoundary(
            key: key,
            child: Scaffold(
              backgroundColor: const Color(0xFFF4F6FB),
              body: ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    clipBehavior: Clip.antiAlias,
                    decoration:
                        BoxDecoration(borderRadius: BorderRadius.circular(16)),
                    child: FittedBox(
                      fit: BoxFit.fitWidth,
                      child: RawImage(image: refImage),
                    ),
                  ),
                  const _Row('Mada', 'Mada — OFL'),
                  const _Row('Vazirmatn', 'Vazirmatn — OFL'),
                  const _Row('Zain', 'Zain — OFL'),
                  const _Row('NotoSansArabic', 'Noto Sans Arabic — OFL'),
                  const _Row('ReadexPro', 'Readex Pro — OFL'),
                  const _Row('Tajawal', 'Tajawal — OFL'),
                  const _Row('Almarai', 'Almarai — OFL'),
                  const _Row('IBMPlexSansArabic',
                      'IBM Plex Sans Arabic — OFL (bundled)'),
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
      await File('$_shotDir/graphik_match.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      // ignore: avoid_print
      print('WROTE graphik_match.png');
    });
  });
}
