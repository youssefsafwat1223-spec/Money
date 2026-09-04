import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/config/legal_urls.dart';

/// C-5 — the Privacy/Terms links must be real before release. CLOSED.
///
/// The URLs were once hardcoded in the Privacy screen pointing at a host that
/// did not resolve, so the shipping build opened a dead link — and both app
/// stores require a reachable privacy URL.
///
/// They now default to https://qirsh.site, which is live over TLS and serves
/// docs/legal/. These tests pin that default, prove the build-time override
/// still works, and keep the generators honest about the exact path segments.
/// Migrated 2026-08-30 from the Workers host, which stays live as the
/// rollback — see Qirsh Production/04_Legal/domain_status.md.
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

  group('the built-in default is the live production legal host', () {
    // C-5 is closed: the default is a host that resolves and serves
    // docs/legal/, so a build that never passes LEGAL_BASE_URL still opens
    // working documents. These assertions pin that default, because a silent
    // edit to it would ship wrong links with nothing else failing.
    //
    // They describe the DEFAULT, so they are meaningful only in a run without
    // --dart-define=LEGAL_BASE_URL. Guarded on that, rather than asserted
    // unconditionally, so passing a staging host at test time does not fail a
    // build for doing exactly what the override exists for.
    const liveHost = 'https://qirsh.site';

    test('default base URL is the approved live host', () {
      if (legalBaseUrlIsBuildOverride) return;
      expect(kLegalBaseUrl, liveHost);
    });

    test('default privacy and terms URLs are exact', () {
      if (legalBaseUrlIsBuildOverride) return;
      expect(kPrivacyPolicyUrl.toString(), '$liveHost/privacy');
      expect(kTermsUrl.toString(), '$liveHost/terms');
    });

    test('the base carries https and a non-empty host', () {
      final base = Uri.parse(kLegalBaseUrl);
      expect(base.scheme, 'https', reason: 'a legal URL must not be plaintext');
      expect(base.host, isNotEmpty);
    });

    test('the base has no trailing slash', () {
      // The paths are appended directly, so a trailing slash here yields
      // '//privacy'. Cheap to assert, easy to reintroduce by hand.
      expect(kLegalBaseUrl.endsWith('/'), isFalse);
      expect(kPrivacyPolicyUrl.path, '/privacy');
      expect(kTermsUrl.path, '/terms');
    });

    test('the dead host it replaced is gone from the config', () {
      // The previous default did not resolve. If it comes back — by a revert,
      // a merge, or a copied line — every shipped link breaks silently.
      final src = File('lib/core/config/legal_urls.dart').readAsStringSync();
      expect(src.contains('mali.youssefsafwat.com'), isFalse,
          reason: 'the unresolvable host must not return as a default');
    });
  });

  group('override resolution', () {
    // Read the define here as well as in the library, so these assertions
    // describe whichever run they are in: `flutter test` proves the fallback,
    // and `flutter test --dart-define=LEGAL_BASE_URL=...` proves the override.
    // Neither case is skipped silently — each is asserted in its own run.
    const override = String.fromEnvironment('LEGAL_BASE_URL');
    const liveHost = 'https://qirsh.site';

    test('an absent or EMPTY define falls back to the live default', () {
      if (override.isNotEmpty) return;
      expect(legalBaseUrlIsBuildOverride, isFalse);
      expect(kLegalBaseUrl, liveHost);
      expect(kPrivacyPolicyUrl.host, Uri.parse(liveHost).host);
    });

    test('an explicit non-empty define wins, and both URLs derive from it', () {
      if (override.isEmpty) return;
      expect(legalBaseUrlIsBuildOverride, isTrue);
      expect(kLegalBaseUrl, override);
      expect(kPrivacyPolicyUrl.toString(), '$override/privacy');
      expect(kTermsUrl.toString(), '$override/terms');
    });
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

  group('the publishable sites match the URLs the app opens', () {
    // Two generators publish docs/legal/, and BOTH must agree with the paths
    // the app opens — otherwise the owner publishes /privacy while the app
    // opens /privacy-policy, and nobody notices until a store reviewer clicks.
    //
    //   build_site.py       -> qirsh.site, the canonical production host
    //   build_legal_site.py -> the Workers host, kept live as the rollback
    //
    // Checking only one would let the other drift, and the one that drifted
    // would be serving a URL nobody can reach.
    const generators = {
      'build_site.py': '../tools/build_site.py',
      'build_legal_site.py': '../tools/build_legal_site.py',
    };

    for (final entry in generators.entries) {
      final name = entry.key;
      final source = File(entry.value).readAsStringSync();

      test('$name exists and is dependency-free', () {
        expect(source, contains('PAGES = {'));
        // A release artifact that needs `pip install` before it can be
        // regenerated is one more thing to fail at the worst moment.
        expect(source.contains('import requests'), isFalse);
        expect(source.contains('import markdown'), isFalse);
      });

      test('$name publishes exactly the paths the app builds', () {
        // kPrivacyPolicyUrl.path is '/privacy'; the generator writes the
        // directory 'privacy' so a static host serves it at that path.
        for (final page in {
          kPrivacyPolicyUrl: 'PRIVACY_POLICY.md',
          kTermsUrl: 'TERMS.md',
        }.entries) {
          final segment = page.key.path.replaceAll('/', '');
          expect(source, contains('"${page.value}": ("$segment"'),
              reason: 'the app opens ${page.key.path} — $name must publish '
                  '${page.value} at that exact segment');
        }
      });

      test('$name renders directory-style, so extensionless URLs resolve', () {
        // /privacy must resolve without a trailing .html, which means
        // privacy/index.html on disk.
        expect(source, contains('index.html'));
        expect(source, contains('dest.mkdir'));
      });

      test('$name fails the build rather than publishing a blank page', () {
        // A silently-empty privacy policy would satisfy a store reviewer's URL
        // check while telling the user nothing.
        expect(source, contains('rendered to'));
        expect(source, matches(RegExp(r'len\(\w+\) < 500')));
      });
    }
  });

  test('the rollback generator is not the one the app points at', () {
    // build_site.py owns qirsh.site. If someone deletes it and leaves only the
    // Workers generator, the production host stops being regenerable — a state
    // that looks fine until docs/legal/ changes and the live site does not.
    expect(File('../tools/build_site.py').existsSync(), isTrue,
        reason: 'tools/build_site.py generates the canonical production site');
    expect(File('../tools/build_legal_site.py').existsSync(), isTrue,
        reason: 'tools/build_legal_site.py still generates the rollback host');
  });

  test('the DEPLOYED site builder emits app-ads.txt', () {
    // The bug this pins: app-ads.txt generation lived ONLY in
    // build_legal_site.py, which writes build/legal/ — while the tree that is
    // actually deployed to qirsh.site comes from build_site.py -> build/site/.
    // Setting ADMOB_PUBLISHER_ID therefore wrote the file into a directory
    // nothing publishes, and AdMob would still see no app-ads.txt.
    //
    // Same two-builder trap that let a false privacy claim stay live: the
    // feature existed, just not in the builder that ships.
    final deployed = File('../tools/build_site.py').readAsStringSync();
    expect(deployed, contains('emit_app_ads_txt'),
        reason: 'build_site.py produces the DEPLOYED tree, so it — not only '
            'build_legal_site.py — must emit app-ads.txt at the domain root');

    // One implementation, imported rather than copied. A second copy is a
    // second thing to forget to update.
    expect(deployed, contains('from build_legal_site import'),
        reason: 'app-ads.txt logic must be shared, not duplicated');

    final shared = File('../tools/build_legal_site.py').readAsStringSync();
    expect(shared, contains('def emit_app_ads_txt('),
        reason: 'the shared emitter must exist where build_site.py imports it');

    // A wrong publisher id authorises the wrong seller, which is worse than
    // having no file at all. Both the shape check and the never-placeholder
    // rule are load-bearing.
    expect(shared, contains(r'pub-\d{16}'),
        reason: 'the publisher id shape check must survive');
    expect(shared, contains('ADMOB_PUBLISHER_ID'),
        reason: 'the id must come from the environment, never be hardcoded');
  });

  test('no AdMob publisher id is hardcoded in the site builders', () {
    // The id belongs in the environment/CI, not in source. A committed id is
    // both a config-in-code smell and, if wrong, a seller-authorisation bug.
    for (final path in const [
      '../tools/build_site.py',
      '../tools/build_legal_site.py',
      '../tools/site_content.py',
    ]) {
      final src = File(path).readAsStringSync();
      expect(RegExp(r'pub-\d{16}').hasMatch(src), isFalse,
          reason: '$path hardcodes an AdMob publisher id');
    }
  });
}
