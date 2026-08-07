// Phase-7 B2-C — brand-mark lookup complexity (obj #6). Proves the memoised
// per-name index makes large row counts NOT re-scan the catalog, while keeping
// the resolution semantics identical.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/cards/brand_mark.dart';

void main() {
  setUp(BrandMark.debugResetBrandCache);

  test('repeated merchant names scan the catalog only ONCE', () {
    for (var i = 0; i < 1000; i++) {
      BrandMark.hasBrand('STARBUCKS COFFEE DOWNTOWN');
    }
    // 1000 rows of the same merchant → a single catalog computation, then O(1)
    // map hits. Before: O(rows × catalog) whole-catalog .contains scans.
    expect(BrandMark.debugStableComputeCount, 1);
  });

  test('hasBrand / logoDevUrlFor share the one memoised computation', () {
    BrandMark.hasBrand('TALABAT');
    BrandMark.logoDevUrlFor('TALABAT');
    BrandMark.hasBrand('TALABAT');
    expect(BrandMark.debugStableComputeCount, 1,
        reason: 'all three calls hit the same cache entry');
  });

  test('distinct names compute once each — O(distinct), not O(rows × catalog)',
      () {
    for (var round = 0; round < 5; round++) {
      for (var i = 0; i < 200; i++) {
        BrandMark.hasBrand('MERCHANT $i');
      }
    }
    // 1000 lookups over 200 distinct names → 200 computations (not 1000, and not
    // 1000 × catalog scans).
    expect(BrandMark.debugStableComputeCount, 200);
  });

  test('semantics preserved: known brands, logo.dev, unknowns, aggregators', () {
    // Bundled SVG brand.
    expect(BrandMark.hasBrand('NETFLIX'), isTrue);
    // Substring match still works ("...NETFLIX..." within a longer name).
    expect(BrandMark.hasBrand('PAYMENT TO NETFLIX INC'), isTrue);
    // logo.dev regional merchant (contains match).
    final url = BrandMark.logoDevUrlFor('TALABAT DELIVERY');
    expect(url, isNotNull);
    expect(url, contains('talabat.com'));
    // Unknown merchant → no brand.
    expect(BrandMark.hasBrand('ZZZ QWX NOSUCH'), isFalse);
    expect(BrandMark.logoDevUrlFor('ZZZ QWX NOSUCH'), isNull);
    // Coloured-letter brand (no SVG, no logo.dev) still counts as a brand.
    expect(BrandMark.hasBrand('AMAZON'), isTrue);
  });

  test('memoised result is identical to a fresh (post-reset) computation', () {
    final names = [
      'NETFLIX',
      'TALABAT',
      'AMAZON',
      'ZZZ UNKNOWN',
      'STARBUCKS',
    ];
    final memoised = {
      for (final n in names) n: (BrandMark.hasBrand(n), BrandMark.logoDevUrlFor(n))
    };
    BrandMark.debugResetBrandCache();
    final fresh = {
      for (final n in names) n: (BrandMark.hasBrand(n), BrandMark.logoDevUrlFor(n))
    };
    expect(memoised, fresh, reason: 'memoisation never changes the answer');
  });

  test('registerAssetSlugs invalidates the index', () {
    BrandMark.hasBrand('ANYTHING');
    expect(BrandMark.debugStableComputeCount, 1);
    // A catalog (re)registration must clear the cache so new slugs take effect.
    BrandMark.registerAssetSlugs(const ['examplebrand']);
    // debugResetBrandCache is separate; registerAssetSlugs clears the map but not
    // the debug counter — a subsequent lookup recomputes (cache was cleared).
    BrandMark.hasBrand('ANYTHING');
    expect(BrandMark.debugStableComputeCount, 2, reason: 're-scanned after clear');
    BrandMark.registerAssetSlugs(const []); // restore empty asset catalog
  });
}
