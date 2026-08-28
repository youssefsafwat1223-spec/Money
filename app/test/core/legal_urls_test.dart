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
            'QIRSH_RELEASE_TRACK.md and remove this assertion');
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
}
