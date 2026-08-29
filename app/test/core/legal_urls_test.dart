import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/config/legal_urls.dart';

/// C-5 — the Privacy/Terms links must be real before release.
///
/// The URLs were hardcoded in the Privacy screen pointing at a host that does
/// not resolve, so the shipping build opens a dead link — and both app stores
/// require a reachable privacy URL.
///
/// This test cannot make the host exist. What it CAN do is make the gap
/// impossible to forget: the placeholder is named, asserted, and tied to the
/// documents that must be published there.
void main() {
  test('the documents that must be published exist in the repo', () {
    // Writing the policy is repository work and is DONE. Only hosting is
    // external. If these are missing, the blocker is no longer just a domain.
    for (final path in const [
      '../docs/legal/PRIVACY_POLICY.md',
      '../docs/legal/TERMS.md',
    ]) {
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: '$path is missing');
      expect(f.readAsStringSync().length, greaterThan(1000),
          reason: '$path looks like a stub');
    }
  });

  test('the policy describes the behaviour the code actually has', () {
    // A privacy policy that misdescribes the software is worse than none. These
    // are the three claims the 2026-08 audit changed, so they are the three
    // most likely to drift back out of truth.
    final policy = File('../docs/legal/PRIVACY_POLICY.md').readAsStringSync();
    expect(policy, contains('off by default'),
        reason: 'consent default is OFF (C-3)');
    expect(policy.toLowerCase(), contains('on your device'),
        reason: 'the AI is on-device with no network path (OD-13)');
    // Matched on a fragment, because the source is hard-wrapped Markdown and
    // asserting a full sentence would fail on reflow rather than on meaning.
    expect(policy, contains('revoking consent is not a deletion'),
        reason: 'revocation and cloud deletion are separate (OD-10)');
  });

  test('the URLs are well-formed and share one host', () {
    for (final uri in [kPrivacyPolicyUrl, kTermsUrl]) {
      expect(uri.scheme, 'https', reason: '$uri must be https');
      expect(uri.host, isNotEmpty);
    }
    expect(kPrivacyPolicyUrl.host, kTermsUrl.host,
        reason: 'both documents are published together; a split host is a '
            'configuration mistake');
  });

  test('the placeholder host is still flagged, not quietly accepted', () {
    // This is the honest state of C-5: everything inside the repository is
    // done, and the host does not resolve. When a real host is configured via
    // --dart-define=LEGAL_BASE_URL, this flips to false and the release
    // checklist item can close.
    //
    // If this assertion ever fails, that is GOOD news — delete it and mark C-5
    // closed. It is written to fail loudly rather than to pass forever.
    expect(legalUrlsArePlaceholder, isTrue,
        reason: 'LEGAL_BASE_URL now points somewhere else — if that host is '
            'live and serving docs/legal/, C-5 is resolved: update '
            'Qirsh Production/01_Current_Status/QIRSH_RELEASE_TRACK.md and remove this assertion');
  });

  test('the screen does not hardcode a URL of its own', () {
    // The original defect was two hardcoded literals. Centralising is only
    // durable if nothing drifts back to a local copy.
    final screen =
        File('lib/features/settings/privacy_screen.dart').readAsStringSync();
    expect(screen.contains('Uri.parse(\'https://'), isFalse,
        reason: 'privacy_screen.dart must take its URLs from '
            'core/config/legal_urls.dart');
  });

  group('an EMPTY --dart-define does not produce a hostless URL', () {
    // CI passes `--dart-define=LEGAL_BASE_URL="${LEGAL_BASE_URL:-}"`, which
    // expands to the empty string whenever the variable is unset in the build
    // environment. `String.fromEnvironment` honours `defaultValue` only for an
    // UNDEFINED key, so an empty define used to win and produce
    // `Uri.parse('/privacy')` — no scheme, no host, unopenable.
    //
    // Worse than the dead link it replaced: a dead link says where it meant to
    // go, and this one is invisible until someone taps it.
    test('the URLs always carry a scheme and host', () {
      expect(kPrivacyPolicyUrl.hasScheme, isTrue);
      expect(kPrivacyPolicyUrl.host, isNotEmpty);
      expect(kTermsUrl.hasScheme, isTrue);
      expect(kTermsUrl.host, isNotEmpty);
    });

    test('the guard is const-evaluable, not a runtime fallback', () {
      // Comparing against '' keeps kLegalBaseUrl a compile-time constant. A
      // runtime fallback would work but would stop the tree-shaker from seeing
      // the value, and would let a null-ish state exist mid-startup.
      final src = File('lib/core/config/legal_urls.dart').readAsStringSync();
      expect(src, contains("_kLegalBaseUrlOverride == ''"));
      expect(src, contains('const String kLegalBaseUrl'));
    });

    test('CI passes the define in every build workflow', () {
      // It was absent from all three, so a CI build shipped the placeholder
      // even after the host went live.
      final ci = File('../codemagic.yaml').readAsStringSync();
      expect('--dart-define=LEGAL_BASE_URL'.allMatches(ci).length, 3,
          reason: 'ios-unsigned-sideload, ios-signed-release and '
              'android-release must all pass it');
    });
  });

  group('the publishable site matches the URLs the app opens', () {
    // Release prep — `tools/build_legal_site.py` renders docs/legal/ into a
    // static site the owner can upload to any host with no build step. The
    // generator and the app must agree on the paths, or the owner publishes
    // /privacy while the app opens /privacy-policy and nobody notices until a
    // store reviewer clicks the link.
    final generator =
        File('../tools/build_legal_site.py').readAsStringSync();

    test('the generator exists and is dependency-free', () {
      expect(generator, contains('PAGES = {'));
      // A release artifact that needs `pip install` before it can be
      // regenerated is one more thing to fail at the worst moment.
      expect(generator.contains('import requests'), isFalse);
      expect(generator.contains('import markdown'), isFalse);
    });

    test('it publishes exactly the paths the app builds', () {
      // kPrivacyPolicyUrl.path is '/privacy'; the generator writes the
      // directory 'privacy' so a static host serves it at that path.
      for (final entry in {
        kPrivacyPolicyUrl: 'PRIVACY_POLICY.md',
        kTermsUrl: 'TERMS.md',
      }.entries) {
        final segment = entry.key.path.replaceAll('/', '');
        expect(generator, contains('"${entry.value}": ("$segment"'),
            reason: 'the app opens ${entry.key.path} — the generator must '
                'publish ${entry.value} at that exact segment');
      }
    });

    test('it renders directory-style, so extensionless URLs resolve', () {
      // /privacy must work without a trailing .html on GitHub Pages, Netlify,
      // Cloudflare Pages and S3 alike — which means privacy/index.html.
      expect(generator, contains('index.html'));
      expect(generator, contains('dest.mkdir'));
    });

    test('an empty render fails the build instead of publishing a blank page',
        () {
      // A silently-empty privacy policy would satisfy a store reviewer's URL
      // check while telling the user nothing.
      expect(generator, contains('rendered to'));
      expect(generator, contains('len(body) < 500'));
    });
  });
}
