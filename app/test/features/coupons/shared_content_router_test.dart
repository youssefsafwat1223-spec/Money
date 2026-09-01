// COUPONS Phase 5 — where shared content goes.
//
// The rule this file defends: A MERCHANT URL MUST NEVER ENTER THE FINANCIAL
// CAPTURE QUEUE. Today every shared text/plain does, which was right when a
// bank message was the only thing anyone shared. A shopping link reaching the
// parser would be read as a transaction — URLs are full of digits and currency
// words — persisted in the encrypted financial store, and synced under
// financial consent.
//
// The classifier leans the OTHER way on purpose: anything ambiguous goes to
// capture. Misrouting a bank message would silently lose a transaction the user
// expected to be recorded, which is worse than showing them a merchant page
// they did not ask for.

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/coupons/shared_content_router.dart';

void main() {
  SharedContent classify(String s) => SharedContentRouter.classify(s);

  group('a bare merchant link is an OFFER intent', () {
    test('with a scheme', () {
      final r = classify('https://noon.com/offers');
      expect(r.kind, SharedContentKind.offerUrl);
      expect(r.host, 'noon.com');
    });

    test('without a scheme', () {
      expect(classify('noon.com').kind, SharedContentKind.offerUrl);
    });

    test('with surrounding whitespace, as every share sheet sends it', () {
      expect(classify('  https://noon.com/x  \n').kind, SharedContentKind.offerUrl);
    });

    test('www is normalised away for the host', () {
      expect(classify('https://www.noon.com/x').host, 'noon.com');
    });
  });

  group('the query string is DESTROYED', () {
    test('session ids, cart ids and referral codes do not survive', () {
      // A shared shopping URL routinely carries all three, plus analytics
      // parameters identifying the person who shared it. None is needed to know
      // which merchant this is — the host alone answers that.
      final r = classify(
        'https://noon.com/product/123?sid=SECRET&cart=abc&ref=USERCODE&utm_source=x#frag',
      );
      expect(r.kind, SharedContentKind.offerUrl);
      expect(r.sanitizedUrl, 'https://noon.com/product/123');
      for (final leaked in ['SECRET', 'abc', 'USERCODE', 'utm_source', 'frag', '?', '#']) {
        expect(r.sanitizedUrl!.contains(leaked), isFalse, reason: leaked);
      }
    });

    test('the sanitized URL is REBUILT, never a substring', () {
      // Rebuilding from parts is what guarantees nothing survives by accident.
      final r = classify('HTTPS://NOON.COM/Path?x=1');
      expect(r.sanitizedUrl, 'https://noon.com/Path');
    });

    test('a bare host gets a root path rather than an empty one', () {
      expect(classify('noon.com').sanitizedUrl, 'https://noon.com/');
    });
  });

  group('anything that might be a bank message goes to CAPTURE', () {
    test('an SMS quoting a URL is still an SMS', () {
      // Misrouting this would silently lose a transaction the user expected to
      // be recorded.
      const sms = 'شراء بمبلغ 320.50 ريال لدى نون\nتفاصيل: https://noon.com/r/1';
      expect(classify(sms).kind, SharedContentKind.capture);
      expect(classify(sms).text, sms);
    });

    test('prose containing a link is not a shared link', () {
      expect(
        classify('check this out https://noon.com/x it is good').kind,
        SharedContentKind.capture,
      );
    });

    test('a very long single line is prose, not a URL', () {
      expect(classify('https://noon.com/${'a' * 600}').kind, SharedContentKind.capture);
    });

    test('a non-http scheme is never followed', () {
      // A shared mailto: or custom scheme is not a merchant link, and following
      // one opens a class of bug we have no reason to.
      for (final s in ['mailto:a@b.com', 'javascript:alert(1)', 'file:///etc/passwd']) {
        expect(classify(s).kind, SharedContentKind.capture, reason: s);
      }
    });

    test('an unresolvable host falls back to capture, not to silence', () {
      // The user shared SOMETHING; the capture path can at least tell them it
      // was not a transaction.
      expect(classify('not..a..host').kind, SharedContentKind.capture);
    });

    test('a plain bank message is unmistakably capture', () {
      expect(classify('خصم 100 ريال من حسابك').kind, SharedContentKind.capture);
    });
  });

  test('empty content is ignored, not enqueued', () {
    for (final s in ['', '   ', '\n\n']) {
      expect(classify(s).kind, SharedContentKind.ignored, reason: '"$s"');
    }
    expect(SharedContentRouter.classify(null).kind, SharedContentKind.ignored);
  });

  test('an offer intent NEVER carries the original text', () {
    // The capture path takes `text`; the offer path takes a rebuilt URL. Keeping
    // the raw string on an offer intent would reintroduce the query string the
    // sanitizer just removed.
    final r = classify('https://noon.com/x?secret=1');
    expect(r.kind, SharedContentKind.offerUrl);
    expect(r.text, isNull);
  });

  test('a capture NEVER carries a sanitized URL', () {
    final r = classify('bank message here');
    expect(r.sanitizedUrl, isNull);
    expect(r.host, isNull);
  });

  test('sanitizeUrl returns empty for anything not an offer link', () {
    expect(SharedContentRouter.sanitizeUrl('https://noon.com/x?a=1'), 'https://noon.com/x');
    expect(SharedContentRouter.sanitizeUrl('a bank message'), '');
    expect(SharedContentRouter.sanitizeUrl('mailto:x@y.com'), '');
  });
}
