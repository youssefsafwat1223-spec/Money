import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/coupons/merchant_alias_key.dart';
import 'package:money_companion/features/coupons/merchant_alias_key_tables.dart';

/// COUPONS Phase 1 — the frozen `merchant_alias_key_v1` contract.
///
/// This key is computed in TWO places: here in Dart, for offline resolution on
/// device, and in PostgreSQL, where it backs a stored generated column and the
/// partial unique index on `catalog_merchant_aliases`. The client cannot call
/// the server (it must resolve offline) and an index expression cannot call
/// Dart, so duplication is forced and drift is the whole risk.
///
/// The `expected` values in the fixture file were computed by the REAL
/// PostgreSQL function on a migrated database and committed. This test asserts
/// Dart against them; `supabase/tests/merchant_alias_key_contract_test.mjs`
/// asserts the live database against the same file. Neither side can move
/// without a visible fixture diff.
void main() {
  final fixtures = jsonDecode(
    File('../docs/coupons/merchant_alias_key_v1.fixtures.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;

  group('merchant_alias_key_v1 — Dart matches the PostgreSQL expectations', () {
    for (final raw in fixtures['name_cases'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      final input = c['input'] as String;
      test('name: ${c['why']}', () {
        expect(
          MerchantAliasKey.name(input),
          c['expected'] as String,
          reason: 'Dart and PostgreSQL disagree on ${jsonEncode(input)} — the '
              'stored key and the device lookup would never meet',
        );
      });
    }

    for (final raw in fixtures['domain_cases'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      test('domain: ${c['why']}', () {
        expect(
          MerchantAliasKey.domain(c['input'] as String),
          c['expected'] as String,
        );
      });
    }
  });

  group('the rules that exist to prevent a WRONG merchant', () {
    test('digits are never stripped', () {
      // Stripping digits — as the three legacy normalizers do — produces
      // stored, cross-user, permanent false merges. Each of these would
      // collapse onto a different real business.
      expect(MerchantAliasKey.name('7-ELEVEN'), '7 eleven');
      expect(MerchantAliasKey.name('360 MALL'), '360 mall');
      expect(MerchantAliasKey.name('FOREVER 21'), 'forever 21');
      expect(MerchantAliasKey.name('STC 5G'), 'stc 5g');
      expect(MerchantAliasKey.name('123'), '123');
      for (final brand in ['7 eleven', '360 mall', 'forever 21']) {
        expect(brand.replaceAll(RegExp(r'[0-9]'), '').trim(),
            isNot(equals(brand)),
            reason: 'sanity: these cases only matter because digit-stripping '
                'would change them');
      }
    });

    test('Persian gaf does NOT fold to Arabic kaf', () {
      // text_normalizer.dart folds it. That is right for a fuzzy classifier and
      // wrong for identity: gaf is a distinct phoneme with no Arabic
      // equivalent, so folding buys no recall in this market and only merges
      // two different names.
      expect(MerchantAliasKey.name('گلستان'),
          isNot(MerchantAliasKey.name('كلستان')));
    });

    test('no Arabic-script letter is silently dropped', () {
      // Regression: the first keep set was U+0621..U+064A only, so Persian peh
      // was treated as a separator and DELETED — پاندا became اندا, which can
      // collide with a real merchant. Dropping punctuation is fine; dropping a
      // LETTER merges distinct names.
      for (final name in ['پاندا', 'چيلي', 'ژالة', 'گلستان']) {
        final key = MerchantAliasKey.name(name);
        expect(key, isNotEmpty);
        expect(key.replaceAll(' ', '').length, name.replaceAll(' ', '').length,
            reason: '$name lost a character in the key');
      }
    });

    test('an empty key is produced, not disguised — callers must abstain', () {
      // Every input that folds away must land on the SAME empty value so the
      // caller can detect it. Silently returning some placeholder would put
      // them all in one bucket that matches each other.
      for (final junk in ['', '   ', '!!!', 'ًٌٍ', '😀😀']) {
        expect(MerchantAliasKey.name(junk), '');
      }
    });

    test('the key strips no boilerplate and no branch numbers', () {
      // Those belong to MerchantLookupPipeline, deliberately OUTSIDE the frozen
      // key: a lexicon inside the key would make every new bank prefix a full
      // key-version migration.
      expect(MerchantAliasKey.name('POS PURCHASE CARREFOUR'),
          'pos purchase carrefour');
      expect(MerchantAliasKey.name('PANDA 123'), 'panda 123');
      expect(MerchantAliasKey.name('CAFE TRACE'), 'cafe trace');
    });

    test('a domain is never folded like a name', () {
      // `7eleven.com` through the NAME folder would key as a different company.
      expect(MerchantAliasKey.domain('7eleven.com'), '7eleven.com');
      expect(MerchantAliasKey.name('7eleven.com'), isNot('7eleven.com'));
      expect(MerchantAliasKey.domain('نون.com'), '',
          reason: 'a Unicode host is rejected, never converted — PostgreSQL '
              'has no matching IDNA implementation');
    });

    test('invisible characters cannot split or shift a key', () {
      // NBSP is the dangerous one: Dart trim() removes it, PostgreSQL btrim()
      // does not. Routing every separator through the keep-set step first is
      // what makes the two agree.
      const plain = 'CARREFOUR';
      for (final invisible in [' ', '​', '﻿', '؜', '　']) {
        expect(MerchantAliasKey.name('$invisible$plain$invisible'),
            MerchantAliasKey.name(plain),
            reason: 'U+${invisible.codeUnitAt(0).toRadixString(16)} changed the key');
      }
      // Tatweel vanishes rather than becoming a separator, so a word stays one
      // word.
      expect(MerchantAliasKey.name('كارفـــور'), MerchantAliasKey.name('كارفور'));
    });

    test('an astral character is one separator, not two', () {
      // Iterating UTF-16 code units would shear the surrogate pair and emit two
      // separators; PostgreSQL works in code points and would emit one.
      expect(MerchantAliasKey.name('CAFE \u{1F600} BAR'), 'cafe bar');
    });
  });

  group('the generated tables are the ones the spec describes', () {
    test('exactly the diacritics the spec lists, and nothing else', () {
      expect(kAliasKeyDiacriticsV1.length, 34);
      expect(kAliasKeyDiacriticsV1.contains(0x0640), isTrue, reason: 'tatweel');
      expect(kAliasKeyDiacriticsV1.contains(0x0670), isTrue,
          reason: 'superscript alef');
      expect(kAliasKeyDiacriticsV1.contains(0x0627), isFalse,
          reason: 'alef is a LETTER — deleting it would destroy names');
    });

    test('gaf is absent from the fold table and present in the keep set', () {
      expect(kAliasKeyLetterFoldsV1.containsKey(0x06AF), isFalse);
      expect(kAliasKeyKeepV1.contains(0x06AF), isTrue);
    });

    test('digits fold to ASCII and are kept', () {
      expect(kAliasKeyDigitFoldsV1[0x0660], 0x30);
      expect(kAliasKeyDigitFoldsV1[0x06F9], 0x39);
      for (var d = 0x30; d <= 0x39; d++) {
        expect(kAliasKeyKeepV1.contains(d), isTrue);
      }
    });

    test('no uppercase ASCII survives into the keep set', () {
      for (var c = 0x41; c <= 0x5A; c++) {
        expect(kAliasKeyKeepV1.contains(c), isFalse,
            reason: 'step 2 folds it away; keeping it too would be a second '
                'path to a different key');
        expect(kAliasKeyCaseFoldsV1[c], c + 0x20);
      }
    });
  });
}
