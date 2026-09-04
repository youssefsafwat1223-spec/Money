import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// iOS source integrity — the cheap half of "does the iOS app build".
///
/// ## Why this exists
///
/// On 2026-09-03 the iOS app was found to be **completely unbuildable**, in
/// exactly the same way the Android app had been a day earlier and for exactly
/// the same feature (offer-URL sharing):
///
///     Swift Compiler Error: Cannot find 'SharedOfferIntentStore' in scope
///     ios/ShareBankMessage/ShareViewController.swift:47
///
/// Both copies of `SharedOfferIntentStore.swift` existed on disk and were
/// correct. Neither had ever been added to a target in
/// `Runner.xcodeproj/project.pbxproj`, so nothing compiled them, while two
/// files that DID compile referenced the type. On iOS a source file that is not
/// in a target's Sources build phase is simply invisible — there is no error
/// for "file on disk that nobody builds", only for the reference that cannot
/// resolve.
///
/// The whole canonical CI suite passed the entire time, because **nothing in
/// this repository compiles iOS**: both Xcode workflows in `codemagic.yaml` are
/// manual-only. This is the iOS half of RB-7.
///
/// `ios/RunnerTests/` holds the equivalent Swift-side contract, but XCTest only
/// runs under Xcode and therefore never runs in CI. These checks are static,
/// run in milliseconds, and live where the suite actually executes. They are
/// NOT a substitute for compiling — see `docs/project/RELEASE_BLOCKERS.md`.

void main() {
  final pbxproj = File('ios/Runner.xcodeproj/project.pbxproj');

  test('every Swift source in a build target is compiled by that target', () {
    // The exact defect: a .swift file sitting in a target's directory that no
    // Sources build phase references. Xcode reports nothing; the linker reports
    // a missing symbol somewhere else entirely.
    expect(pbxproj.existsSync(), isTrue, reason: 'project.pbxproj missing');
    final project = pbxproj.readAsStringSync();

    final orphans = <String>[];
    for (final dir in const ['ios/Runner', 'ios/ShareBankMessage']) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.swift')) continue;
        final name = f.uri.pathSegments.last;
        // A file is compiled iff a PBXBuildFile names it "in Sources". The
        // PBXFileReference alone is not enough — a file can be listed in the
        // navigator and still be built by nobody, which is precisely the bug.
        if (!project.contains('$name in Sources')) orphans.add(f.path);
      }
    }

    expect(orphans, isEmpty,
        reason: 'These Swift files are on disk but in no target\'s Sources '
            'build phase, so nothing compiles them. Any reference to them from '
            'a file that IS compiled fails with "Cannot find X in scope". Add '
            'them to Runner.xcodeproj (PBXBuildFile + PBXFileReference + group '
            'child + Sources phase entry).');
  });

  test('both copies of each App-Group store stay byte-identical', () {
    // These types are duplicated per target rather than shared, because the
    // share extension is a separate binary. Two copies that drift are two
    // different serialization formats over ONE App Group container — the
    // extension writes a payload the app cannot read back.
    //
    // RunnerTests.swift asserts this for SharedCaptureStore, but XCTest does
    // not run in CI. SharedOfferIntentStore had the same two-copy shape and no
    // check at all.
    for (final name in const [
      'SharedCaptureStore.swift',
      'SharedOfferIntentStore.swift',
    ]) {
      final a = File('ios/Runner/$name');
      final b = File('ios/ShareBankMessage/$name');
      expect(a.existsSync(), isTrue, reason: '${a.path} missing');
      expect(b.existsSync(), isTrue, reason: '${b.path} missing');
      expect(a.readAsBytesSync(), b.readAsBytesSync(),
          reason: 'The two copies of $name have drifted. They share one App '
              'Group container and must serialize identically. Edit both '
              'together.');
    }
  });
}
