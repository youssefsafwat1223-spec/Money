import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';

class _BrokenPhotos extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) {
    if (key.endsWith('.webp')) return Future.error(StateError('broken photo'));
    return rootBundle.load(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every approved bundled photograph decodes as a real image', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final photo in QirshPhoto.values) {
      expect(manifest.listAssets(), contains(photo.assetPath));
      final bytes = await rootBundle.load(photo.assetPath);
      final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List(
          bytes.offsetInBytes, bytes.lengthInBytes));
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1200, reason: photo.name);
      expect(frame.image.height, 800, reason: photo.name);
      frame.image.dispose();
      codec.dispose();
    }
  });

  test('all original light and dark SVGs compile into nonempty pictures',
      () async {
    for (final theme in ['', 'dark/']) {
      for (final name in QirshIllustration.names) {
        final picture = await vg.loadPicture(
            SvgAssetLoader('assets/illustrations/$theme$name.svg'), null);
        expect(picture.size, const Size(160, 120), reason: '$theme$name');
        picture.picture.dispose();
      }
    }
  });

  testWidgets('a dark photo failure shows its actual themed illustration',
      (tester) async {
    await tester.pumpWidget(DefaultAssetBundle(
      bundle: _BrokenPhotos(),
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(
          body: QirshPhotoFrame(photo: QirshPhoto.wallet, height: 150),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(QirshIllustration), findsOneWidget);
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect((svg.bytesLoader as SvgAssetLoader).assetName,
        'assets/illustrations/dark/budget.svg');
    expect(tester.takeException(), isNull);
  });

  testWidgets('card copy stays physically right in Arabic and English',
      (tester) async {
    for (final direction in [TextDirection.rtl, TextDirection.ltr]) {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Directionality(
          textDirection: direction,
          child: const Scaffold(
            body: SizedBox(
              width: 400,
              child: QirshPhotoCard(
                photo: QirshPhoto.growth,
                child: Text('Savings', key: ValueKey('copy')),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final card = tester.getRect(find.byType(QirshPhotoCard));
      final copy = tester.getRect(find.byKey(const ValueKey('copy')));
      expect(copy.center.dx, greaterThan(card.center.dx));
      expect(tester.takeException(), isNull);
    }
  });
}
