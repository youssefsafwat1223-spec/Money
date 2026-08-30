/// The one place the Privacy/Terms URLs are configured.
///
/// These were once hardcoded in `privacy_screen.dart`, pointing at a host that
/// did not resolve. They are centralised here so there is a single canonical
/// base, one place to change it, and a test that can assert the URLs are
/// well-formed and consistent.
///
/// ## The default is the real production host, on purpose
///
/// [_kLegalBaseUrl] is the live legal site. It is a working default, not a
/// placeholder: a build that fails to pass `LEGAL_BASE_URL` still opens
/// reachable documents rather than dead links.
///
/// That is a deliberate reversal. The default used to be an unresolvable host,
/// so that a missing CI variable would be caught. But it was only catchable by
/// tapping the link in a finished build — which in practice means a store
/// reviewer finds it, after submission. Degrading to *working* links is the
/// safer failure mode, and CI still passes the define explicitly in all three
/// build workflows.
///
/// The host must keep serving the documents in `docs/legal/`, published by
/// `tools/build_legal_site.py`. `legal_urls_test.dart` asserts the generator
/// and these URLs agree on the exact path segments.
library;

/// Live legal site. Serves `/privacy` and `/terms` from `docs/legal/`.
///
/// No trailing slash: the paths below are appended directly, so a trailing
/// slash here would produce `//privacy`.
const String _kLegalBaseUrl = 'https://qirsh-legal.albaraai-dev.workers.dev';

/// Raw build-time override. May be EMPTY — see [kLegalBaseUrl].
const String _kLegalBaseUrlOverride = String.fromEnvironment('LEGAL_BASE_URL');

/// Base host for the published legal documents.
///
/// Override at build time to point at a different host:
///   --dart-define=LEGAL_BASE_URL=https://your-host.example
///
/// ## Why this is not a plain `defaultValue:`
///
/// `String.fromEnvironment` falls back to `defaultValue` only when the key is
/// UNDEFINED. A key defined as the empty string returns the empty string — and
/// CI passes `--dart-define=LEGAL_BASE_URL="${LEGAL_BASE_URL:-}"`, which
/// expands to exactly that whenever the variable is not set in the build
/// environment.
///
/// With a bare `defaultValue:` that build produced `Uri.parse('/privacy')` — a
/// relative URI with no scheme and no host, which `url_launcher` cannot open.
/// The failure mode was worse than the dead link it replaced: a dead link at
/// least tells the user where it meant to go, and this one is invisible until
/// someone taps it, which for a store reviewer is exactly once.
///
/// Comparing against `''` keeps the whole expression const-evaluable, so this
/// stays a compile-time constant.
const String kLegalBaseUrl =
    _kLegalBaseUrlOverride == '' ? _kLegalBaseUrl : _kLegalBaseUrlOverride;

/// Published from `docs/legal/PRIVACY_POLICY.md`.
final Uri kPrivacyPolicyUrl = Uri.parse('$kLegalBaseUrl/privacy');

/// Published from `docs/legal/TERMS.md`.
final Uri kTermsUrl = Uri.parse('$kLegalBaseUrl/terms');

/// Whether this build carries an explicit `LEGAL_BASE_URL` override.
///
/// `false` means the built-in production host is in use, which is a supported
/// and safe state — not a defect. Exposed so a build can be identified
/// mechanically (for example, to confirm a staging define actually landed)
/// rather than by reading URLs out of a binary.
///
/// This replaces the former `legalUrlsArePlaceholder`, which asked whether the
/// default was still in use back when the default was an unresolvable host.
/// With a working default that question no longer indicates anything.
bool get legalBaseUrlIsBuildOverride => _kLegalBaseUrlOverride != '';
