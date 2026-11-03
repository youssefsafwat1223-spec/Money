import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/auth_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AuthDiagnostics.debugReset);
  tearDown(AuthDiagnostics.debugReset);

  test('keeps the newest entries first, up to the capacity', () {
    for (var i = 0; i < AuthDiagnostics.capacity + 3; i++) {
      AuthDiagnostics.add('e$i');
    }
    final lines = AuthDiagnostics.entries.value;
    expect(lines, hasLength(AuthDiagnostics.capacity));
    expect(lines.first, endsWith(' e${AuthDiagnostics.capacity + 2}'));
    expect(lines.last, endsWith(' e3'));
  });

  test('persists across a fresh attach; malformed content starts empty',
      () async {
    final dir = await Directory.systemTemp.createTemp('auth_diag');
    addTearDown(() => dir.delete(recursive: true));
    await AuthDiagnostics.attach(dir);
    AuthDiagnostics.add('asr_stop record:none');
    final file = File('${dir.path}/${AuthDiagnostics.fileName}');
    for (var i = 0; i < 50 && !await file.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    AuthDiagnostics.debugReset();
    await AuthDiagnostics.attach(dir);
    expect(AuthDiagnostics.entries.value.single, endsWith('asr_stop record:none'));

    await file.writeAsString('{not json');
    AuthDiagnostics.debugReset();
    await AuthDiagnostics.attach(dir);
    expect(AuthDiagnostics.entries.value, isEmpty);
  });
}
