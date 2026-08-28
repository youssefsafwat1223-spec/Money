/// C-5 — the one place the Privacy/Terms URLs are configured.
///
/// These were hardcoded in `privacy_screen.dart` pointing at a host that does
/// not resolve (NXDOMAIN, re-verified 2026-08-27, for both
/// `mali.youssefsafwat.com` and the apex domain). The in-app Privacy screen
/// therefore opens a dead link in the shipping build, and both app stores
/// require a reachable privacy URL.
///
/// Centralising them does not fix that — only owning a host does — but it makes
/// the fix a one-line change in a file named for the purpose, and it lets a test
/// assert the URLs are at least well-formed and consistent.
///
/// ## Deliberately NOT defaulted to a plausible-looking URL
///
/// It would be easy to point these at some real-looking address to make the
/// release checklist go green. That would be worse than the current state: a
/// link that resolves to someone else's page, or to a 404 on a domain we do not
/// control, is a privacy policy the user cannot read while appearing to be one.
/// The host below is the intended one and is recorded as a RELEASE BLOCKER until
/// it resolves and serves the documents in `docs/legal/`.
library;

/// Base host for the published legal documents.
///
/// Override at build time once the host is live and serving:
///   --dart-define=LEGAL_BASE_URL=https://your-host.example
const String kLegalBaseUrl = String.fromEnvironment(
  'LEGAL_BASE_URL',
  defaultValue: 'https://mali.youssefsafwat.com',
);

/// Published from `docs/legal/PRIVACY_POLICY.md`.
final Uri kPrivacyPolicyUrl = Uri.parse('$kLegalBaseUrl/privacy');

/// Published from `docs/legal/TERMS.md`.
final Uri kTermsUrl = Uri.parse('$kLegalBaseUrl/terms');

/// Whether the configured host is the unresolved placeholder.
///
/// Exposed so the release checklist can assert on it mechanically rather than
/// relying on someone remembering. It is NOT used to hide the links in the UI:
/// showing a dead link is bad, but silently removing the privacy policy from a
/// shipping app is worse, and the correct fix is to own the host.
bool get legalUrlsArePlaceholder =>
    kLegalBaseUrl == 'https://mali.youssefsafwat.com';
