import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// MALI-014 §Blocker-1 — production-call-site contract: destructive restore mutation
// can ONLY be reached through the canonical prepare → confirmation → commitRestore
// boundary. This source scan fails the gate if any production file introduces a
// combined bypass or calls the mutation primitives directly.

Iterable<File> _libDartFiles() sync* {
  final lib = Directory('${Directory.current.path}/lib');
  for (final e in lib.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) yield e;
  }
}

void main() {
  test('no production code exposes or calls a combined prepare+commit bypass', () {
    for (final f in _libDartFiles()) {
      final src = f.readAsStringSync();
      // The old combined API is removed — no production restoreFromBackup/restore
      // entry point may exist.
      expect(src.contains('restoreFromBackup'), isFalse,
          reason: '${f.path} must not use the removed combined restore API');
    }
  });

  test('commitRestore is only reached via the RestoreController mutate callback',
      () {
    final callers = <String>[];
    for (final f in _libDartFiles()) {
      final src = f.readAsStringSync();
      if (RegExp(r'\.commitRestore\(').hasMatch(src)) {
        callers.add(f.path.split('/').last);
      }
    }
    // Only the screen (which wires the controller) references commitRestore; the
    // controller invokes it via the injected mutate callback.
    expect(callers.toSet(), {'restore_prompt_screen.dart'},
        reason: 'unexpected commitRestore caller(s): $callers');
  });

  test('RestoreService.execute and RestoreBackupUseCase.call are confined to the '
      'backup service layer', () {
    final execCallers = <String>[];
    final useCaseCallers = <String>[];
    for (final f in _libDartFiles()) {
      final src = f.readAsStringSync();
      final base = f.path.split('/').last;
      if (RegExp(r'_restoreService\.execute\(|RestoreService\([^)]*\)\.execute\(')
          .hasMatch(src)) {
        execCallers.add(base);
      }
      if (RegExp(r'RestoreBackupUseCase\([^)]*\)\.call\(|RestoreBackupUseCase\([^)]*\)\(')
          .hasMatch(src)) {
        useCaseCallers.add(base);
      }
    }
    expect(execCallers.toSet(), {'encrypted_backup_service.dart'});
    expect(useCaseCallers.toSet(), {'restore_service.dart'});
  });
}
