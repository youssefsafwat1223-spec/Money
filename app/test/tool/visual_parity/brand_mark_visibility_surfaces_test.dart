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
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/brand_mark_visibility_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'brand-visibility-memory';
  @override
  Future<String?> readStoredKey() async => 'brand-visibility-memory';
}

Future<bool>? _opening;

class _Launch extends ConsumerWidget {
  const _Launch(this.keyName);
  final String keyName;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
      body: TextButton(
          onPressed: () {
            _opening =
                openVisualParityBrandMarkVisibility(context, ref, keyName);
          },
          child: const Text('Open actual mark')));
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

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await vg.waitForPendingDecodes();
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest
        .listAssets()
        .where((path) =>
            path.startsWith('assets/brands/') && path.endsWith('.svg'))
        .toList();
    expect(paths, hasLength(138));
    // Exact production bootstrap registration with the actual bundled catalog.
    BrandMark.registerAssetSlugs(
        paths.map((path) => path.split('/').last.replaceAll('.svg', '')));
  });
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
  });
  tearDown(() async => db.close());
  for (final name in ['SONY', 'APPLE']) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets(
            'actual $name visible with default denied consent $language dark=$dark',
            (tester) async {
          var httpAttempts = 0;
          await HttpOverrides.runZoned(() async {
            tester.view.physicalSize = const Size(375, 667);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.runAsync(() async {
              final font = FontLoader('Vazirmatn');
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                font.addFont(
                    rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
              }
              await font.load();
            });
            final before = await tester.runAsync(() => _snapshot(db));
            final key = name == 'SONY' ? 'brandMarkSony' : 'brandMarkApple';
            final events = visualParityBrandMarkVisibilityEvents();
            await tester.pumpWidget(ProviderScope(
                overrides: [appDatabaseProvider.overrideWithValue(db)],
                child: MaterialApp(
                    theme: dark ? AppTheme.dark : AppTheme.light,
                    locale: Locale(language),
                    supportedLocales: AppL10n.supportedLocales,
                    localizationsDelegates: AppL10n.localizationsDelegates,
                    home: _Launch(key))));
            final container =
                ProviderScope.containerOf(tester.element(find.byType(_Launch)));
            final settings = (await tester
                .runAsync(() => container.read(userSettingsProvider.future)))!;
            expect(settings.cloudProcessingEnabled, isFalse);
            expect(container.read(remoteMerchantLogosAllowedProvider), isFalse);
            expect(BrandMark.hasBrand(name), isTrue);
            await tester.runAsync(() async {
              await tester.tap(find.text('Open actual mark'));
              expect(await _opening, isTrue);
            });
            for (var i = 0; i < 5; i++) {
              await _settle(tester);
            }
            final mark = find.byType(BrandMark);
            expect(mark, findsOneWidget);
            expect(tester.widget<BrandMark>(mark).name, name);
            final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
            expect((svg.bytesLoader as SvgAssetLoader).assetName,
                'assets/brands/${name.toLowerCase()}.svg');
            expect(svg.colorFilter, isNull);
            expect(find.byType(Image), findsNothing);
            expect(Theme.of(tester.element(mark)).brightness,
                dark ? Brightness.dark : Brightness.light);
            final tile = tester.widget<Container>(find
                .descendant(of: mark, matching: find.byType(Container))
                .first);
            final background = (tile.decoration! as ShapeDecoration).color!;
            final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(ValueKey('brandMarkRaster:$name')));
            final image =
                (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
            try {
              final bytes = (await tester.runAsync(
                  () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
              expect(image.width, 96);
              expect(image.height, 96);
              var contrasting = 0;
              // Excludes rounded tile edges. Original glyph remains centered
              // inside the production18% padding, so only actual artwork can
              // differ strongly from this actual uniform tile background.
              for (var y = 18; y < 78; y++) {
                for (var x = 18; x < 78; x++) {
                  final offset = (y * image.width + x) * 4;
                  final distance =
                      (bytes.getUint8(offset) - (background.r * 255).round())
                              .abs() +
                          (bytes.getUint8(offset + 1) -
                                  (background.g * 255).round())
                              .abs() +
                          (bytes.getUint8(offset + 2) -
                                  (background.b * 255).round())
                              .abs();
                  if (bytes.getUint8(offset + 3) > 200 && distance > 180) {
                    contrasting++;
                  }
                }
              }
              const directory =
                  String.fromEnvironment('BRAND_MARK_EVIDENCE_DIR');
              if (directory.isNotEmpty) {
                final target = Directory(directory)
                  ..createSync(recursive: true);
                final png = (await tester.runAsync(
                    () => image.toByteData(format: ui.ImageByteFormat.png)))!;
                final data = png.buffer
                    .asUint8List(png.offsetInBytes, png.lengthInBytes);
                final id = '$name-$language-${dark ? 'dark' : 'light'}';
                File('${target.path}/$id.png').writeAsBytesSync(data);
                File('${target.path}/$id.json').writeAsStringSync(jsonEncode({
                  'name': name,
                  'language': language,
                  'dark': dark,
                  'backgroundArgb': background.toARGB32(),
                  'contrastingGlyphPixels': contrasting,
                  'pngSha256': sha256.convert(data).toString(),
                  'actualRemoteConsent': settings.cloudProcessingEnabled,
                  'httpClientAttempts': httpAttempts,
                  'svg': (svg.bytesLoader as SvgAssetLoader).assetName
                }));
              }
              expect(contrasting, greaterThan(20),
                  reason:
                      'Actual $name glyph must contrast with its actual tile');
              expect(background,
                  name == 'SONY' ? AppBrandBlue.deep : Colors.white);
            } finally {
              image.dispose();
            }
            expect(await tester.runAsync(() => _snapshot(db)), before);
            Navigator.of(tester.element(mark)).pop();
            await _settle(tester);
            for (var i = 0;
                i < 10 &&
                    visualParityBrandMarkVisibilityEvents()['${key}Closed'] !=
                        (events['${key}Closed'] ?? 0) + 1;
                i++) {
              await _settle(tester);
            }
            expect(visualParityBrandMarkVisibilityEvents()['${key}Closed'],
                (events['${key}Closed'] ?? 0) + 1);
            expect(container.read(remoteMerchantLogosAllowedProvider), isFalse);
            expect(await tester.runAsync(() => _snapshot(db)), before);
            expect(httpAttempts, 0);
            expect(tester.takeException(), isNull);
          }, createHttpClient: (context) {
            httpAttempts++;
            throw StateError('actual mark must never construct remote client');
          });
        });
      }
    }
  }
  testWidgets('unknown actual mark key avoids provider reads', (tester) async {
    bool? handled;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => throw StateError('no read'))
        ],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      handled = await openVisualParityBrandMarkVisibility(
                          context, ref, 'unknown');
                    },
                    child: const Text('Unknown'))))));
    await tester.tap(find.text('Unknown'));
    await tester.pump();
    expect(handled, isFalse);
  });
  testWidgets('file parent rejects actual mark before settings or route',
      (tester) async {
    final directory = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('qirsh-mark-file-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/db.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => _snapshot(disk));
    Object? rejection;
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(disk)],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      try {
                        await openVisualParityBrandMarkVisibility(
                            context, ref, 'brandMarkSony');
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
    expect(find.byType(BrandMark), findsNothing);
    expect(await tester.runAsync(() => _snapshot(disk)), before);
  });
}
