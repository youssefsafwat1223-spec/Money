import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/brand_asset_atlas.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'brand-atlas-test-memory';
  @override
  Future<String?> readStoredKey() async => 'brand-atlas-test-memory';
}

Future<bool>? _opening;

class _Launch extends ConsumerWidget {
  const _Launch(this.keyName);
  final String keyName;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
      body: TextButton(
          onPressed: () {
            _opening = openVisualParityBrandAssetAtlas(context, ref, keyName);
          },
          child: const Text('Open brand atlas')));
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((row) => row.data)
          .toList()
  };
}

Future<void> _decodeFrames(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await vg.waitForPendingDecodes();
  });
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase parent;
  final nativeCalls = <String>[];
  setUp(() async {
    parent = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
    nativeCalls.clear();
    for (final channel in [
      'plugins.flutter.io/flutter_secure_storage',
      'dexterous.com/flutter/local_notifications',
      'com.youssefsafwat.mali/capture',
      'plugins.flutter.io/firebase_messaging',
      'plugins.flutter.io/google_mobile_ads'
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (call) async {
        nativeCalls.add('$channel:${call.method}');
        return null;
      });
    }
  });
  tearDown(() async => parent.close());

  testWidgets(
      'every manifest brand decodes and actual SvgPicture paints nonempty alpha',
      (tester) async {
    final paths = (await tester.runAsync(visualParityBrandAssetPaths))!;
    expect(paths, hasLength(138));
    expect(paths, orderedEquals([...paths]..sort()));
    expect(paths.toSet(), hasLength(paths.length));
    final parentBefore = await tester.runAsync(() => _snapshot(parent));
    const directory = String.fromEnvironment('BRAND_ATLAS_EVIDENCE_DIR');
    final evidence = directory.isEmpty
        ? null
        : (Directory(directory)..createSync(recursive: true));
    final proof = <Map<String, Object?>>[];
    void writeProof() {
      if (evidence != null) {
        File('${evidence.path}/brand-raster-proof.json')
            .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
          'assets': proof,
          'manifestPaths': paths,
          'decoder':
              'Installed flutter_svg SvgAssetLoader + vg.loadPicture; actual SvgPicture.asset RepaintBoundary.toImage96x96 transparent raster',
          'scope':
              'Raw bundled SVG rendering only. Does not prove BrandMark name mappings, fallbacks or remote logos.'
        }));
      }
    }

    for (final path in paths) {
      PictureInfo? picture;
      ui.Image? raster;
      try {
        final source = (await tester.runAsync(() => rootBundle.load(path)))!;
        final bytes = source.buffer
            .asUint8List(source.offsetInBytes, source.lengthInBytes);
        expect(bytes, isNotEmpty, reason: path);
        // These exact public APIs and disposal obligations are documented in
        // the locally installed flutter_svg2.3.0/vector_graphics1.2.2 source.
        final loader = SvgAssetLoader(path);
        final compiled = (await tester.runAsync(() => loader.loadBytes(null)))!;
        expect(compiled.lengthInBytes, greaterThan(0), reason: path);
        final decodeErrors = <Object>[];
        picture = (await tester.runAsync(
            () => vg.loadPicture(loader, null, onError: (error, stack) {
                  decodeErrors.add(error);
                })))!;
        expect(decodeErrors, isEmpty, reason: path);
        expect(
            picture.size.width.isFinite && picture.size.height.isFinite, isTrue,
            reason: path);
        expect(picture.size.isEmpty, isFalse, reason: path);
        expect(picture.picture.approximateBytesUsed, greaterThan(0),
            reason: path);
        final vectorSize = picture.size;
        final vectorBytes = picture.picture.approximateBytesUsed;
        var loaded = false;
        final paintErrors = <Object>[];
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
                child: RepaintBoundary(
                    key: boundaryKey,
                    child: SvgPicture.asset(path, width: 96, height: 96,
                        imageBuilder: (context, child) {
                      loaded = true;
                      return child;
                    }, errorBuilder: (context, error, stack) {
                      paintErrors.add(error);
                      return const SizedBox(width: 96, height: 96);
                    })))));
        for (var i = 0; i < 20 && !loaded && paintErrors.isEmpty; i++) {
          await _decodeFrames(tester);
        }
        expect(paintErrors, isEmpty, reason: path);
        expect(loaded, isTrue,
            reason: 'Actual SvgPicture placeholder never resolved: $path');
        await tester.pump();
        final boundary = boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        raster =
            (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
        expect(raster.width, 96, reason: path);
        expect(raster.height, 96, reason: path);
        final rgba = (await tester.runAsync(
            () => raster!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
        var alphaPixels = 0;
        for (var i = 3; i < rgba.lengthInBytes; i += 4) {
          if (rgba.getUint8(i) > 0) alphaPixels++;
        }
        expect(alphaPixels, greaterThan(0),
            reason:
                'Actual transparent raster has no painted SVG pixel: $path');
        String? pngSha;
        if (evidence != null) {
          final png = (await tester.runAsync(
              () => raster!.toByteData(format: ui.ImageByteFormat.png)))!;
          final pngBytes =
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
          File('${evidence.path}/${path.split('/').last}.png')
              .writeAsBytesSync(pngBytes);
          pngSha = sha256.convert(pngBytes).toString();
        }
        proof.add({
          'path': path,
          'sha256': sha256.convert(bytes).toString(),
          'sourceBytes': bytes.length,
          'compiledBytes': compiled.lengthInBytes,
          'vectorWidth': vectorSize.width,
          'vectorHeight': vectorSize.height,
          'pictureBytes': vectorBytes,
          'rasterWidth': raster.width,
          'rasterHeight': raster.height,
          'nonzeroAlphaPixels': alphaPixels,
          'pngSha256': pngSha,
          'decoderErrors': 0,
          'paintErrors': 0,
          'passed': true
        });
        writeProof();
        expect(tester.takeException(), isNull, reason: path);
      } catch (error) {
        proof.add({'path': path, 'passed': false, 'error': error.toString()});
        writeProof();
        rethrow; // Report the first exact asset; no repairs or hidden fallback.
      } finally {
        raster?.dispose();
        picture?.picture.dispose();
      }
    }
    expect(proof, hasLength(138));
    expect(await tester.runAsync(() => _snapshot(parent)), parentBefore);
    expect(nativeCalls, isEmpty);
  });

  for (var page = 0; page < visualParityBrandAssetAtlasKeys.length; page++) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets(
            'public atlas page$page $language dark=$dark all tiles bounded',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            for (final family in [
              'Vazirmatn',
              'Alexandria',
              'IBMPlexSansArabic'
            ]) {
              final loader = FontLoader(family);
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                loader.addFont(
                    rootBundle.load('assets/fonts/$family-$weight.ttf'));
              }
              await loader.load();
            }
          });
          final paths = (await tester.runAsync(visualParityBrandAssetPaths))!;
          final selected = paths.skip(page * 24).take(24).toList();
          final key = visualParityBrandAssetAtlasKeys[page];
          final events = visualParityBrandAssetAtlasEvents();
          final before = await tester.runAsync(() => _snapshot(parent));
          await tester.pumpWidget(ProviderScope(
              overrides: [appDatabaseProvider.overrideWithValue(parent)],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: _Launch(key))));
          final navigator =
              tester.state<NavigatorState>(find.byType(Navigator));
          await tester.runAsync(() async {
            await tester.tap(find.text('Open brand atlas'));
            expect(await _opening, isTrue);
          });
          for (var i = 0; i < 4; i++) {
            await _decodeFrames(tester);
          }
          expect(find.byType(SvgPicture), findsNWidgets(page == 5 ? 18 : 24));
          expect(find.text('Brand assets ${page + 1}/6'), findsOneWidget);
          expect(
              find.text(
                  '${page * 24 + 1}–${page * 24 + selected.length} / 138'),
              findsOneWidget);
          expect(
              Theme.of(tester.element(find.byType(SvgPicture).first))
                  .brightness,
              dark ? Brightness.dark : Brightness.light);
          final seen = <String>[];
          for (final svg
              in tester.widgetList<SvgPicture>(find.byType(SvgPicture))) {
            expect(svg.bytesLoader, isA<SvgAssetLoader>());
            seen.add((svg.bytesLoader as SvgAssetLoader).assetName);
            expect(svg.colorFilter, isNull);
          }
          expect(seen, orderedEquals(selected));
          for (final path in selected) {
            final tile = find.byKey(ValueKey('brandAtlasTile:$path'));
            final widget = tester.widget<Container>(tile);
            expect((widget.decoration! as BoxDecoration).color, Colors.white);
            await tester.ensureVisible(tile);
            await tester.pumpAndSettle();
            final bounds = tester.getRect(tile);
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(375));
            expect(bounds.top, greaterThanOrEqualTo(0));
            expect(bounds.bottom, lessThanOrEqualTo(667));
            expect(tile.hitTestable(), findsOneWidget);
            final label = find.text(path.split('/').last);
            final paragraph = tester.renderObject<RenderParagraph>(label);
            expect(paragraph.didExceedMaxLines, isFalse, reason: path);
          }
          expect(visualParityBrandAssetAtlasErrors(), isEmpty);
          expect(await tester.runAsync(() => _snapshot(parent)), before);
          navigator.pop();
          await tester.pumpAndSettle();
          for (var i = 0;
              i < 20 &&
                  visualParityBrandAssetAtlasEvents()['${key}Closed'] !=
                      (events['${key}Closed'] ?? 0) + 1;
              i++) {
            await _decodeFrames(tester);
          }
          expect(visualParityBrandAssetAtlasEvents()['${key}Opened'],
              (events['${key}Opened'] ?? 0) + 1);
          expect(visualParityBrandAssetAtlasEvents()['${key}Closed'],
              (events['${key}Closed'] ?? 0) + 1);
          expect(await tester.runAsync(() => _snapshot(parent)), before);
          expect(nativeCalls, isEmpty);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets('unknown atlas key reads no provider', (tester) async {
    bool? handled;
    final events = visualParityBrandAssetAtlasEvents();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider
              .overrideWith((ref) => throw StateError('must not read database'))
        ],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      handled = await openVisualParityBrandAssetAtlas(
                          context, ref, 'unrelated');
                    },
                    child: const Text('Unknown'))))));
    await tester.tap(find.text('Unknown'));
    await tester.pump();
    expect(handled, isFalse);
    expect(visualParityBrandAssetAtlasEvents(), events);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file parent rejects atlas before opening any page',
      (tester) async {
    final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('qirsh-brand-guard-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/parent.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => _snapshot(disk));
    final events = visualParityBrandAssetAtlasEvents();
    Object? rejection;
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(disk)],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      try {
                        await openVisualParityBrandAssetAtlas(
                            context, ref, 'brandAssetAtlas0');
                      } catch (error) {
                        rejection = error;
                      }
                    },
                    child: const Text('File'))))));
    await tester.runAsync(() async {
      await tester.tap(find.text('File'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(rejection, isA<StateError>());
    expect(visualParityBrandAssetAtlasEvents(), events);
    expect(await tester.runAsync(() => _snapshot(disk)), before);
    expect(find.byType(SvgPicture), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
