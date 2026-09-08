// Runs the Dart integration test under XCTest — Flutter's documented iOS path
// for CI (`flutter build ios --config-only -t integration_test/<file>`, then
// `xcodebuild test`). XCTest launches the app through Xcode tooling and
// collects results itself, so no Dart VM Service discovery over mDNS is
// involved; that discovery is what stalled `flutter test` on a physical
// iOS 26 device for up to 22 minutes per run. A DEBUG engine refuses to start
// under testmanagerd (ptrace denied), so run this with -configuration Profile.
//
// GATED, deliberately. RunnerTests is also the home of the Swift unit tests,
// and FLTIntegrationTestRunner spins the run loop with NO timeout until the
// Dart side reports results. Whenever Flutter/Generated.xcconfig's
// FLUTTER_TARGET points at lib/main.dart — i.e. after any ordinary
// `flutter run` — an ungated runner would block `xcodebuild test` forever
// during test enumeration and silently take every Swift unit test with it.
// So this class only exists when the integration invocation says so:
//
//   xcodebuild test ... -configuration Profile \
//     -only-testing:RunnerTests/RunnerIntegrationTests \
//     GCC_PREPROCESSOR_DEFINITIONS='$(inherited) QIRSH_INTEGRATION_TEST=1'
//
// The Dart target is whatever `--config-only -t` last wrote (FLUTTER_TARGET);
// this file is target-agnostic.
#if QIRSH_INTEGRATION_TEST
@import XCTest;
@import integration_test;

INTEGRATION_TEST_IOS_RUNNER(RunnerIntegrationTests)
#endif
