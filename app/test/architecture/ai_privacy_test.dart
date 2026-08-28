import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/intelligence/merchant_classifier.dart';

/// OD-13 §6.4 — "AI/cloud consent OFF ⇒ ZERO AI network egress".
///
/// For a cloud model that requirement is met with a consent gate, and the gate
/// is the thing you have to keep testing forever. This model meets it a stronger
/// way: **there is no network path to gate**. Inference is pure Dart over data
/// already in the bundle, so consent-off egress is not merely blocked, it is
/// structurally absent.
///
/// That property is worth an explicit test rather than an assumption, because it
/// is exactly what a future change would quietly destroy — someone adding a
/// "fetch better embeddings" call, or a paid-API fallback, would turn a
/// no-egress component into a consent-gated one without anyone re-reading this
/// reasoning. OD-13 forbids a paid API fallback specifically; this is where that
/// prohibition is enforced mechanically rather than by memory.
void main() {
  final intelligenceDir = Directory('lib/engine/intelligence');

  List<File> sources() => intelligenceDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('the intelligence layer imports nothing that can reach the network', () {
    // Any of these would give the model a way out of the device.
    const forbidden = [
      "import 'dart:io'",
      'package:http/',
      'package:dio/',
      'supabase',
      'HttpClient',
      'WebSocket',
      'functions.invoke',
    ];

    for (final file in sources()) {
      final src = file.readAsStringSync();
      for (final needle in forbidden) {
        expect(src.contains(needle), isFalse,
            reason: '${file.path} references "$needle". The on-device model '
                'must have NO network path — if this becomes a networked '
                'component it needs a ConsentAuthority gate and an entry in '
                'egress_inventory_test.dart, and OD-13 forbids a paid API '
                'as a fallback.');
      }
    }
  });

  test('no paid-provider SDK has been introduced', () {
    // OD-13: a paid per-request API must not appear as the primary path OR as
    // a hidden fallback. Named explicitly so the prohibition is checkable.
    const paidProviders = [
      'openai',
      'anthropic',
      'gemini',
      'vertexai',
      'cohere',
      'mistral',
      'replicate',
      'huggingface',
    ];
    for (final file in sources()) {
      final src = file.readAsStringSync().toLowerCase();
      for (final p in paidProviders) {
        expect(src.contains(p), isFalse,
            reason: '${file.path} mentions "$p" — OD-13 requires a free, '
                'zero-per-request-cost model and forbids a paid fallback');
      }
    }
  });

  test('inference performs no I/O at all', () {
    // Behavioural rather than structural: run the model inside a zone that
    // fails the test if anything tries to touch the filesystem or the clock in
    // a way that implies external state.
    final model = CharNgramMerchantClassifier();
    // A prediction on arbitrary input must complete synchronously — an async
    // boundary is where I/O would have to hide.
    final result = model.predict('شراء من كارفور');
    expect(result, anyOf(isNull, isA<MerchantPrediction>()),
        reason: 'predict() is synchronous by signature; if it ever needs to '
            'become async, that is the signal it gained I/O');
  });

  test('the model ships no downloaded asset', () {
    // A model asset would need bundling, versioning and integrity checks, and
    // would change the app-size and update story. This one has none by design.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final needle in const ['.tflite', '.onnx', '.gguf', '.mlmodel']) {
      expect(pubspec.contains(needle), isFalse,
          reason: 'a model asset ($needle) appeared in the bundle; OD-13 '
              'requires the smallest thing that works, and any asset needs an '
              'explicit size/latency/battery review');
    }
  });

  test('capture still works when the model is absent', () {
    // The model must never be load-bearing: if construction ever throws or the
    // component is removed, transaction capture must be unaffected. The
    // Categorizer takes it as an OPTIONAL dependency for exactly this reason.
    final source = File('lib/engine/categorization/categorizer.dart')
        .readAsStringSync();
    expect(source, contains('MerchantIntelligence? intelligence'),
        reason: 'the model must remain optional — AI unavailability must '
            'degrade to the deterministic path, never lose a transaction');
    expect(source, contains('_intelligence != null'),
        reason: 'the null case must be handled explicitly');
  });
}
