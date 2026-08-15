// MALI-COUPONS (C5.1) — the catalog CROSS-BOUNDARY contract.
//
// C5 live validation found `catalog-coupons` emitting `image_path` while the
// Dart parser read `image_url`: two halves that were each internally consistent
// and separately green, so no existing suite could see the gap. Every coupon
// would have silently fallen back to the accent BrandMark in production.
//
// This suite derives the contract from the REAL sources on both sides — the
// TypeScript `CouponSnapshotItem` interface and the actual Dart parser — so it
// cannot drift again without failing. It deliberately does NOT restate the
// schema by hand; a hand-written third copy would just be a third thing to
// drift.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _edgeSource = '../supabase/functions/catalog-coupons/index.ts';
const _modelSource = 'lib/features/coupons/coupon_models.dart';

String _read(String path) => File(path).readAsStringSync();

/// Top-level field names of the Edge response DTO, read from the interface.
Set<String> _edgeDtoFields() {
  final src = _read(_edgeSource);
  final start = src.indexOf('export interface CouponSnapshotItem {');
  expect(start, greaterThan(-1), reason: 'CouponSnapshotItem must exist');
  final end = src.indexOf('\n}', start);
  final block = src.substring(start, end);
  return block
      .split('\n')
      .skip(1)
      .map((l) => RegExp(r'^  (\w+)\??:').firstMatch(l)?.group(1))
      .whereType<String>()
      .toSet();
}

/// Every top-level key the Dart snapshot parser actually reads.
Set<String> _dartConsumedKeys() => RegExp(r"json\['(\w+)'\]")
    .allMatches(_read(_modelSource))
    .map((m) => m.group(1)!)
    .toSet();

void main() {
  test('every field the Edge serves is consumed by the mobile parser', () {
    final served = _edgeDtoFields();
    final consumed = _dartConsumedKeys();
    expect(served, isNotEmpty);
    final unconsumed = served.difference(consumed);
    expect(
      unconsumed,
      isEmpty,
      reason: 'catalog-coupons serves fields the client never reads: $unconsumed '
          '— either the client is missing them or they should not be in the DTO',
    );
  });

  test('the parser reads nothing the Edge does not serve', () {
    final served = _edgeDtoFields();
    final consumed = _dartConsumedKeys();
    final unserved = consumed.difference(served);
    expect(
      unserved,
      isEmpty,
      reason: 'the client reads keys catalog-coupons never sends: $unserved '
          '— these silently parse as null in production (the C5 image defect)',
    );
  });

  test('C5.1: image_url is the mobile contract; image_path stays server-side', () {
    final edge = _read(_edgeSource);
    final dart = _read(_modelSource);

    // The response carries the resolved URL…
    expect(_edgeDtoFields(), contains('image_url'));
    // …and never the raw storage path (that would make bucket layout a client
    // concern and re-open exactly the defect this suite exists for).
    expect(_edgeDtoFields().contains('image_path'), isFalse);

    // The DB column is still read from PostgREST — it remains the authority.
    expect(edge.contains('accent_hex, image_path,'), isTrue,
        reason: 'the column is still selected; only the DTO changed');

    // The client consumes the URL and composes nothing.
    expect(dart.contains("json['image_url']"), isTrue);
    expect(dart.contains('coupon-assets'), isFalse,
        reason: 'the app must never know the bucket name');
    expect(dart.contains('/storage/v1/object'), isFalse,
        reason: 'the app must never compose a storage URL');
  });

  test('C5.1: the Edge resolves URLs only from the trusted server base', () {
    final edge = _read(_edgeSource);
    // Composition is fed by the handler's SUPABASE_URL, never by the request.
    expect(edge.contains('buildSnapshot(rows, now, supabaseUrl)'), isTrue);
    for (final untrusted in [
      "req.headers.get('host')",
      'req.headers.get("host")',
      'X-Forwarded-Host',
    ]) {
      expect(edge.contains(untrusted), isFalse,
          reason: 'asset URLs must not derive from $untrusted');
    }
  });

  test('C5.1: the nullability shape of the DTO matches what the parser expects',
      () {
    final edge = _read(_edgeSource);
    // Fields the model treats as required must not be optional in the DTO.
    for (final required in [
      'id: string;',
      'slug: string;',
      'partner_name: string;',
      'title_ar: string;',
      'description_ar: string;',
      'valid_from: string;',
    ]) {
      expect(edge.contains(required), isTrue, reason: 'DTO must keep $required');
    }
    // …and the ones the model accepts as null must stay nullable.
    for (final nullable in [
      'image_url: string | null;',
      'code: string | null;',
      'partner_url: string | null;',
      'accent_hex: string | null;',
      'valid_until: string | null;',
    ]) {
      expect(edge.contains(nullable), isTrue, reason: 'DTO must keep $nullable');
    }
  });
}
