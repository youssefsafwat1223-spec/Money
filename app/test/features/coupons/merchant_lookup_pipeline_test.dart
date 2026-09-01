// COUPONS Phase 1 — MerchantLookupPipeline.v1, against a REAL database.
//
// Every test here is about the same question: when the pipeline is unsure, does
// it abstain? A miss costs the user an offer they might have liked. A wrong
// match tells someone — from reading their bank messages — that they shop
// somewhere they have never been. Those are not symmetric errors, and nothing
// in this file should ever be relaxed to improve recall.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/coupons/merchant_alias_key.dart';
import 'package:money_companion/features/coupons/merchant_lookup_pipeline.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late RemoteMerchantAliasesDao aliases;
  late MerchantLookupPipeline pipeline;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    await db.initialize();
    aliases = RemoteMerchantAliasesDao(db);
    pipeline = MerchantLookupPipeline(aliases);
  });
  tearDown(() => db.close());

  /// Stores an alias the way the SERVER would: the key is computed by the same
  /// contract the database's generated column uses, never hand-written.
  Future<void> alias(
    String merchantId,
    String raw, {
    String kind = 'name',
    String? country,
    int priority = 0,
  }) =>
      aliases.upsertAll([
        RemoteMerchantAlias(
          id: '$merchantId-$raw-${country ?? 'global'}-$kind',
          merchantId: merchantId,
          aliasNormalized: kind == 'name'
              ? MerchantAliasKey.name(raw)
              : MerchantAliasKey.domain(raw),
          aliasKind: kind,
          countryCode: country,
          priority: priority,
          keyVersion: 1,
          isActive: true,
          isDeleted: false,
          updatedVersion: 1,
        )
      ]);

  group('resolution', () {
    test('an exact reviewed alias resolves', () async {
      await alias('m-carrefour', 'CARREFOUR');
      final r = await pipeline.resolve('Carrefour');
      expect(r.isResolved, isTrue);
      expect(r.merchantId, 'm-carrefour');
      expect(r.stage, MerchantMatchStage.exact);
    });

    test('Arabic orthography variants reach the same merchant', () async {
      // The whole reason for the fold table: bank text writes these
      // interchangeably, and without folding the catalog would need a row per
      // spelling.
      await alias('m-sharika', 'شركة النور');
      for (final variant in ['شركه النور', 'شَرِكة النور', 'شركــة النور']) {
        final r = await pipeline.resolve(variant);
        expect(r.merchantId, 'm-sharika', reason: variant);
      }
    });

    test('a bank wrapper is stripped at stage 2', () async {
      await alias('m-noon', 'NOON');
      final r = await pipeline.resolve('POS PURCHASE NOON');
      expect(r.merchantId, 'm-noon');
      expect(r.stage, MerchantMatchStage.stripped);
    });

    test('a doubled wrapper is stripped too', () async {
      // One pass would leave the inner wrapper attached and produce a key no
      // admin would ever have catalogued.
      await alias('m-noon', 'NOON');
      expect((await pipeline.resolve('POS PURCHASE PAYMENT TO NOON')).merchantId,
          'm-noon');
    });

    test('a branch number is stripped, but only with digits', () async {
      await alias('m-panda', 'بنده');
      expect((await pipeline.resolve('بنده فرع ٤٥')).merchantId, 'm-panda');
    });

    test('a domain resolves through the separate domain contract', () async {
      await alias('m-noon', 'noon.com', kind: 'domain');
      final r = await pipeline.resolve('unknown string',
          merchantUrl: 'https://WWW.Noon.com/offers?x=1');
      expect(r.merchantId, 'm-noon');
      expect(r.stage, MerchantMatchStage.domain);
    });
  });

  group('the pipeline abstains rather than guess', () {
    test('an uncatalogued merchant is noMatch, never a near miss', () async {
      await alias('m-carrefour', 'CARREFOUR');
      final r = await pipeline.resolve('SOME OTHER SHOP');
      expect(r.outcome, MerchantMatchOutcome.noMatch);
      expect(r.merchantId, isNull);
    });

    test('a string that folds away is ambiguous, never looked up', () async {
      // Every one of these produces the SAME empty key. Looking it up would put
      // them all in one bucket that matches whatever landed there first.
      await alias('m-x', 'X SHOP');
      for (final junk in ['!!!', '   ', '؟؟؟', '😀']) {
        final r = await pipeline.resolve(junk);
        expect(r.outcome, MerchantMatchOutcome.ambiguous, reason: junk);
      }
    });

    test('two merchants claiming one key in one scope is ambiguous', () async {
      // The server's partial unique index forbids creating this, so reaching it
      // means the cache is mid-update or an assignment changed. Picking one at
      // random would attribute spending to a business by luck.
      await alias('m-a', 'AMBIGUOUS BRAND');
      await alias('m-b', 'AMBIGUOUS BRAND');
      final r = await pipeline.resolve('Ambiguous Brand');
      expect(r.outcome, MerchantMatchOutcome.ambiguous);
      expect(r.merchantId, isNull);
    });

    test('a deactivated or tombstoned alias stops resolving', () async {
      await alias('m-gone', 'WITHDRAWN SHOP');
      expect((await pipeline.resolve('WITHDRAWN SHOP')).isResolved, isTrue);
      await aliases.markDeleted(['m-gone-WITHDRAWN SHOP-global-name']);
      expect((await pipeline.resolve('WITHDRAWN SHOP')).outcome,
          MerchantMatchOutcome.noMatch);
    });

    test('an alias with an unknown key_version is never stored or used', () async {
      // A future v2 key means something this build cannot interpret. Storing it
      // would leave a row that looks resolvable and is not.
      await aliases.upsertAll([
        const RemoteMerchantAlias(
          id: 'future', merchantId: 'm-future', aliasNormalized: 'future shop',
          aliasKind: 'name', priority: 0, keyVersion: 2,
          isActive: true, isDeleted: false, updatedVersion: 1,
        )
      ]);
      expect(await aliases.count(), 0);
      expect((await pipeline.resolve('FUTURE SHOP')).outcome,
          MerchantMatchOutcome.noMatch);
    });
  });

  group('unstripped-first ordering is a safety property', () {
    test('a full catalogued name beats a stripped interpretation', () async {
      // The case both reviewers used. If stage 2 ran first with an over-eager
      // lexicon, "PAYMENT SOLUTIONS" would resolve to the OTHER merchant.
      await alias('m-payment-solutions', 'PAYMENT SOLUTIONS');
      await alias('m-solutions', 'SOLUTIONS');
      final r = await pipeline.resolve('Payment Solutions');
      expect(r.merchantId, 'm-payment-solutions');
      expect(r.stage, MerchantMatchStage.exact);
    });

    test('bare wrapper words are not in the lexicon at all', () async {
      // `payment`, `pos`, `purchase`, `شراء`, `دفع` alone must never be
      // stripped — they start real business names.
      await alias('m-solutions', 'SOLUTIONS');
      for (final name in ['PAYMENT SOLUTIONS', 'POS SOLUTIONS', 'شراء SOLUTIONS']) {
        expect((await pipeline.resolve(name)).outcome,
            MerchantMatchOutcome.noMatch,
            reason: '$name was reduced to SOLUTIONS');
      }
    });

    test('a marker without digits is not noise', () async {
      // text_normalizer.dart uses `[0-9]*`, so it turns "CAFE TRACE" into
      // "CAFE". Here the digits are required.
      await alias('m-cafe', 'CAFE');
      expect((await pipeline.resolve('CAFE TRACE')).outcome,
          MerchantMatchOutcome.noMatch);
      expect((await pipeline.resolve('CAFE TERM 4471')).merchantId, 'm-cafe');
    });

    test('digits inside a brand are never treated as a branch number', () async {
      await alias('m-711', '7-ELEVEN');
      await alias('m-eleven', 'ELEVEN');
      expect((await pipeline.resolve('7-ELEVEN')).merchantId, 'm-711');
      expect((await pipeline.resolve('FOREVER 21')).outcome,
          MerchantMatchOutcome.noMatch,
          reason: 'must not strip to FOREVER and must not match ELEVEN');
    });
  });

  group('country scope needs merchant evidence, not the device', () {
    test('with no evidence, only global aliases are used', () async {
      await alias('m-sa', 'REGIONAL BRAND', country: 'SA');
      final r = await pipeline.resolve('Regional Brand');
      expect(r.outcome, MerchantMatchOutcome.noMatch,
          reason: 'a country-scoped alias must not be used without evidence '
              'about where the MERCHANT is');
    });

    test('a country-scoped alias wins over global WITH evidence', () async {
      await alias('m-global', 'SPLIT BRAND');
      await alias('m-sa', 'SPLIT BRAND', country: 'SA');
      final r = await pipeline.resolve('Split Brand',
          evidence: const MerchantLocationEvidence(merchantCountry: 'SA'));
      expect(r.merchantId, 'm-sa');
    });

    test('evidence for another country falls back to global, never to that one',
        () async {
      await alias('m-global', 'SPLIT BRAND');
      await alias('m-sa', 'SPLIT BRAND', country: 'SA');
      final r = await pipeline.resolve('Split Brand',
          evidence: const MerchantLocationEvidence(merchantCountry: 'EG'));
      expect(r.merchantId, 'm-global');
    });

    test('a scope with no global fallback yields no match', () async {
      await alias('m-sa', 'SA ONLY BRAND', country: 'SA');
      final r = await pipeline.resolve('SA Only Brand',
          evidence: const MerchantLocationEvidence(merchantCountry: 'EG'));
      expect(r.outcome, MerchantMatchOutcome.noMatch);
    });
  });

  group('stripLookupNoise mirrors what the database refuses to store', () {
    test('it removes exactly the catalogued noise forms', () {
      const strip = MerchantLookupPipeline.stripLookupNoise;
      expect(strip('POS PURCHASE CARREFOUR'), 'carrefour');
      expect(strip('PAYMENT TO NOON'), 'noon');
      expect(strip('شراء من كارفور'), 'كارفور');
      expect(strip('CARREFOUR TERM 4471'), 'carrefour');
      expect(strip('بنده فرع ٤٥'), 'بنده');
    });

    test('it leaves real names alone', () {
      const strip = MerchantLookupPipeline.stripLookupNoise;
      expect(strip('PAYMENT SOLUTIONS'), 'payment solutions');
      expect(strip('CAFE TRACE'), 'cafe trace');
      expect(strip('7-ELEVEN'), '7 eleven');
      expect(strip('FOREVER 21'), 'forever 21');
    });
  });
}
