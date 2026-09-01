// COUPONS Phase 5 — the native share boundary.
//
// The project has no JVM test source set for Android, so the Kotlin router is
// covered by structural assertions over its source rather than by executing it —
// the same arrangement as the SMS prefilter, and recorded as such. These catch a
// regression that reintroduces the single-queue behaviour; they cannot prove
// runtime behaviour on a device.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/coupons/shared_content_router.dart';

String _read(String path) => File(path).readAsStringSync();

/// Kotlin with comments stripped. Load-bearing: the SMS receiver spent months
/// commented out while a naive grep reported it as present.
///
/// Quote-aware, because the naive version is wrong in the opposite direction
/// here: `startsWith("https://")` contains `//` inside a string literal, and
/// cutting at the first `//` deletes the very code these tests check for. That
/// mistake made four of them fail against a correct implementation.
/// Block comments go too. `DurableCaptureQueue` is NAMED in the offer store's
/// KDoc — in the sentence explaining why the two stores are separate — and a
/// line-only stripper reads that prose as a code reference.
String _code(String path) => _read(path)
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map(_stripLineComment)
    .join('\n');

String _stripLineComment(String line) {
  var inString = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"' && (i == 0 || line[i - 1] != r'\')) {
      inString = !inString;
    } else if (!inString && ch == '/' && i + 1 < line.length && line[i + 1] == '/') {
      return line.substring(0, i);
    }
  }
  return line;
}

void main() {
  const mainActivity =
      'android/app/src/main/kotlin/com/example/money_companion/MainActivity.kt';
  const router =
      'android/app/src/main/kotlin/com/example/money_companion/SharedContentRouter.kt';
  const store =
      'android/app/src/main/kotlin/com/example/money_companion/OfferIntentStore.kt';

  group('a merchant URL can never reach the financial capture queue', () {
    test('the share handler CLASSIFIES before it enqueues', () {
      final code = _code(mainActivity);
      final classifyAt = code.indexOf('SharedContentRouter.classify');
      final captureEnqueueAt = code.indexOf('DurableCaptureQueue.get(this).enqueue');
      expect(classifyAt, greaterThan(-1),
          reason: 'shared text must be routed, not enqueued blindly');
      expect(classifyAt, lessThan(captureEnqueueAt),
          reason: 'a URL must be diverted BEFORE anything reaches the capture queue');
    });

    test('the capture enqueue is inside the Capture branch only', () {
      final code = _code(mainActivity);
      final captureBranch = code.indexOf('Result.Capture ->');
      final offerBranch = code.indexOf('Result.OfferUrl ->');
      final captureEnqueue = code.indexOf('DurableCaptureQueue.get(this).enqueue');
      final offerEnqueue = code.indexOf('OfferIntentStore.enqueue');
      expect(offerBranch, lessThan(offerEnqueue));
      expect(captureBranch, lessThan(captureEnqueue));
      expect(offerEnqueue, lessThan(captureBranch),
          reason: 'the offer branch must not fall through into capture');
    });

    test('the two stores are genuinely separate', () {
      // One store with a "kind" column would let a query reach the parser
      // through a single missed filter. Two stores make it impossible.
      final storeCode = _code(store);
      expect(storeCode.contains('DurableCaptureQueue'), isFalse,
          reason: 'the offer store must not touch the capture queue');
      expect(storeCode.contains('qirsh_offer_intents'), isTrue);
    });
  });

  group('the offer store refuses anything unsanitized', () {
    test('a URL with a query or fragment is rejected at the store', () {
      // The caller sanitizes; this is the second lock, because a raw URL
      // reaching disk is the outcome the whole design prevents.
      final code = _code(store);
      expect(code.contains("contains('?')"), isTrue);
      expect(code.contains("contains('#')"), isTrue);
      expect(code.contains('startsWith("https://")'), isTrue);
    });

    test('the store is bounded', () {
      // A hand-off buffer, not a queue. Unbounded growth here means something is
      // wrong and the right answer is to drop the oldest.
      expect(_code(store).contains('MAX_ITEMS'), isTrue);
    });
  });

  group('the Kotlin router mirrors the Dart specification', () {
    test('both reject a non-http scheme before prepending', () {
      // mailto:a@b.com with https:// glued on parses as host b.com — a shared
      // email address would have become an offer link to the recipient's
      // domain. Both implementations must check the scheme FIRST.
      final kotlin = _code(router);
      expect(kotlin.contains('ANY_SCHEME'), isTrue);
      final anySchemeAt = kotlin.indexOf('ANY_SCHEME.containsMatchIn');
      final prependAt = kotlin.indexOf('"https://\$text"');
      expect(anySchemeAt, greaterThan(-1));
      expect(anySchemeAt, lessThan(prependAt));

      // And the Dart side agrees on the behaviour itself.
      expect(SharedContentRouter.classify('mailto:a@b.com').kind,
          SharedContentKind.capture);
    });

    test('both reject URL credentials', () {
      expect(_code(router).contains('userInfo'), isTrue);
      expect(SharedContentRouter.classify('https://user:pw@noon.com/x').kind,
          SharedContentKind.capture);
    });

    test('both REBUILD the sanitized URL rather than substring it', () {
      // Rebuilding from parts is what guarantees nothing from the query
      // survives by accident.
      expect(_code(router).contains('"https://" +'), isTrue);
      expect(SharedContentRouter.sanitizeUrl('https://noon.com/p?sid=SECRET#f'),
          'https://noon.com/p');
    });

    test('both share the same length bound and www rule', () {
      final kotlin = _code(router);
      expect(kotlin.contains('MAX_URL_SHARE_LENGTH = 512'), isTrue);
      expect(kotlin.contains('startsWith("www.")'), isTrue);
      expect(SharedContentRouter.classify('https://www.noon.com/x').host, 'noon.com');
    });

    test('the Kotlin file names the Dart file as its specification', () {
      // Two implementations of one rule need a stated authority, or they drift
      // into two rules.
      expect(_read(router).contains('shared_content_router.dart'), isTrue);
    });
  });
}
