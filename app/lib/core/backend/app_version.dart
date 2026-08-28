/// F-024 — the canonical client version identity.
///
/// Six call sites read `String.fromEnvironment('APP_VERSION')` directly and no
/// build defines it, so every one of them sent an EMPTY string. That is not a
/// cosmetic gap: `X-App-Version` is what the catalog endpoints use to decide
/// which announcements, feature flags and force-update rows apply to a client.
/// An empty version means version-targeted rules cannot match, so a
/// force-update aimed at "clients below 0.2.0" silently reaches nobody — a
/// safety control that reports success while doing nothing.
///
/// The failure mode is the dangerous one: it is invisible. No error, no warning,
/// just a header that is always `''`, and a targeting rule that never fires.
///
/// ## Why a fallback constant rather than PackageInfo
///
/// Reading the real bundle version at runtime would need `package_info_plus` as
/// a direct dependency (it is currently only transitive) and would make the
/// value async, which the const header maps cannot use. The fallback below is a
/// plain constant, and [appVersionMatchesPubspec] in the test suite fails if it
/// ever drifts from `pubspec.yaml` — so the constant cannot rot silently, which
/// was the whole defect.
library;

/// The version this client reports to the server.
///
/// A build may override it with `--dart-define=APP_VERSION=x.y.z`; CI does. When
/// it is absent — local runs, tests, and any build that forgets the define — the
/// value falls back to the version compiled into this binary rather than to an
/// empty string.
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: kPubspecVersion,
);

/// Kept in lockstep with `pubspec.yaml`'s `version:` field (the part before
/// `+`). Enforced by `app_version_test.dart`, which reads pubspec and compares.
///
/// Update BOTH when bumping a release.
const String kPubspecVersion = '0.1.3';

/// The header every catalog request must carry.
///
/// Exposed as a single map so no call site re-derives it — the original defect
/// was six independent copies of the same expression, which is exactly how five
/// of them would have been missed by a fix applied to one.
const Map<String, String> kAppVersionHeaders = {'X-App-Version': kAppVersion};
