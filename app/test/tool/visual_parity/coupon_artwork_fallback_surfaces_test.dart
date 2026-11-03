import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/rendering.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/coupons/coupon_widgets.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/coupon_artwork_fallback_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'manual-edit-parent-memory';
  @override
  Future<String?> readStoredKey() async => 'manual-edit-parent-memory';
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
                openVisualParityCouponArtworkFallback(context, ref, keyName);
          },
          child: const Text('Open edit fixture')));
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
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await tester.pump(const Duration(milliseconds: 150));
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
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('actual nonhttps artwork fallback $language dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var httpCalls = 0;
        await HttpOverrides.runZoned(() async {
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(
                  rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await font.load();
          });
          final parentBefore = await tester.runAsync(() => _snapshot(parent));
          const key = 'couponNonhttpsFallback';
          final events = visualParityCouponArtworkFallbackEvents();
          await tester.pumpWidget(ProviderScope(
              overrides: [appDatabaseProvider.overrideWithValue(parent)],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: const _Launch(key))));
          final outer = tester.state<NavigatorState>(find.byType(Navigator));
          final parentContainer =
              ProviderScope.containerOf(tester.element(find.byType(_Launch)));
          final writer = parentContainer.read(transactionRepositoryProvider);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await _settle(tester);
          });
          await tester.runAsync(() async {
            await tester.tap(find.text('Open edit fixture'));
            expect(await _opening, isTrue);
          });
          for (var i = 0; i < 6; i++) {
            await _settle(tester);
          }
          await tester.pump(const Duration(seconds: 1));
          await _settle(tester);
          final card = find.byType(CouponCard);
          expect(card, findsOneWidget);
          final context = tester.element(card);
          final childContainer = ProviderScope.containerOf(context);
          final child = childContainer.read(appDatabaseProvider);
          expect(child, isNot(same(parent)));
          final cached = (await tester.runAsync(
              () => childContainer.read(cachedCouponsProvider.future)))!;
          expect(cached, hasLength(1));
          final offer = cached.single;
          expect(offer.imageUrl, 'http://fixture.invalid/logo.png');
          expect(tester.widget<CouponCard>(card).offer, same(offer));
          expect(
              childContainer.read(remoteMerchantLogosAllowedProvider), isFalse);
          final settings = (await tester.runAsync(
              () => childContainer.read(userSettingsProvider.future)))!;
          expect(settings.cloudProcessingEnabled, isFalse);
          final mark = tester.widget<BrandMark>(find.byType(BrandMark));
          expect(mark.name, 'APPLE');
          expect(find.byType(Image), findsNothing);
          final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
          expect((svg.bytesLoader as SvgAssetLoader).assetName,
              'assets/brands/apple.svg');
          expect(svg.colorFilter, isNull);
          await tester.runAsync(() => vg.waitForPendingDecodes());
          await tester.pumpAndSettle();
          final rasterFinder =
              find.byKey(const ValueKey('coupon-artwork-raster'));
          final boundary =
              tester.renderObject<RenderRepaintBoundary>(rasterFinder);
          final markRect = tester
              .getRect(find.byType(BrandMark))
              .shift(-tester.getTopLeft(rasterFinder));
          final image =
              (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
          try {
            final data = (await tester.runAsync(
                () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
            var darkGlyphPixels = 0;
            for (var y = (markRect.top + markRect.height * .2).ceil();
                y < markRect.bottom - markRect.height * .2;
                y++) {
              for (var x = (markRect.left + markRect.width * .2).ceil();
                  x < markRect.right - markRect.width * .2;
                  x++) {
                final offset = (y * image.width + x) * 4;
                if (data.getUint8(offset) < 100 &&
                    data.getUint8(offset + 1) < 100 &&
                    data.getUint8(offset + 2) < 100 &&
                    data.getUint8(offset + 3) > 200) {
                  darkGlyphPixels++;
                }
              }
            }
            expect(darkGlyphPixels, greaterThan(20),
                reason:
                    'Actual local Apple SVG must paint, not remain an empty placeholder');
          } finally {
            image.dispose();
          }

          expect(
              find.text(language == 'en'
                  ? 'Local synthetic offer'
                  : 'عرض تجريبي محلي'),
              findsOneWidget);
          expect(find.text('QAART'), findsOneWidget);
          expect(
              tester
                  .renderObject<RenderParagraph>(find.text('QAART'))
                  .didExceedMaxLines,
              isFalse);
          final before = await tester.runAsync(() => _snapshot(child));
          await tester.pump(const Duration(seconds: 1));
          await _settle(tester);
          expect(await tester.runAsync(() => _snapshot(child)), before);
          expect(
              childContainer
                  .read(couponAnalyticsProvider)
                  .claimedImpressionCount,
              1,
              reason:
                  'Actual impression method is allowed to claim in-memory; transport remains fail-closed');
          expect(parentContainer.read(transactionRepositoryProvider),
              same(writer));
          expect(await tester.runAsync(() => _snapshot(parent)), parentBefore);
          expect(nativeCalls, isEmpty);
          expect(httpCalls, 0);
          outer.pop();
          for (var i = 0;
              i < 40 &&
                  (visualParityCouponArtworkFallbackEvents()['${key}Closed'] ??
                          0) ==
                      (events['${key}Closed'] ?? 0);
              i++) {
            await _settle(tester);
          }
          expect(visualParityCouponArtworkFallbackEvents()['${key}Closed'],
              (events['${key}Closed'] ?? 0) + 1);
          expect(
              visualParityCouponArtworkFallbackEvents()[
                  '${key}AllSqlUnchanged'],
              (events['${key}AllSqlUnchanged'] ?? 0) + 1);
          expect(
              visualParityCouponArtworkFallbackEvents()['${key}ForbiddenTap'] ??
                  0,
              events['${key}ForbiddenTap'] ?? 0);
          final receipt = visualParityCouponArtworkFallbackReceipts()[key]!;
          expect(receipt['childAllSqlUnchanged'], isTrue);
          expect(receipt['actualCloudProcessingEnabled'], isFalse);
          expect(receipt['actualRemoteLogosAllowed'], isFalse);
          expect(await tester.runAsync(() => _snapshot(parent)), parentBefore);
          expect(httpCalls, 0);
          expect(tester.takeException(), isNull);
        }, createHttpClient: (context) {
          httpCalls++;
          throw StateError('fallback must not construct HTTP client');
        });
      });
    }
  }
  testWidgets('unknown edit key accesses no provider', (tester) async {
    bool? handled;
    final events = visualParityCouponArtworkFallbackEvents();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider
              .overrideWith((ref) => throw StateError('must not read provider'))
        ],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      handled = await openVisualParityCouponArtworkFallback(
                          context, ref, 'unrelated');
                    },
                    child: const Text('Unknown'))))));
    await tester.tap(find.text('Unknown'));
    await tester.pump();
    expect(handled, isFalse);
    expect(visualParityCouponArtworkFallbackEvents(), events);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file parent rejected before any child fixture', (tester) async {
    final directory = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('qirsh-edit-guard-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/parent.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => _snapshot(disk));
    final events = visualParityCouponArtworkFallbackEvents();
    Object? rejection;
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(disk)],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      try {
                        await openVisualParityCouponArtworkFallback(
                            context, ref, 'couponNonhttpsFallback');
                      } catch (error) {
                        rejection = error;
                      }
                    },
                    child: const Text('File'))))));
    await tester.runAsync(() async {
      await tester.tap(find.text('File'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(rejection, isA<StateError>());
    expect(visualParityCouponArtworkFallbackEvents(), events);
    expect(await tester.runAsync(() => _snapshot(disk)), before);
    expect(find.byType(CouponCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
