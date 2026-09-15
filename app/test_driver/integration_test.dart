import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Driver for screenshot-producing integration tests.
///
/// `takeScreenshot` inside a test only asks the host for a capture; the bytes
/// come back HERE, and without this driver they are discarded. Runs as:
///
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/store_screenshots_test.dart \
///     -d <simulator udid>
///
/// Every other integration test in this repo runs through `flutter test`, which
/// needs no driver. This file exists solely for the screenshot path.
Future<void> main() async {
  final outDir = Platform.environment['QIRSH_SCREENSHOT_DIR'] ??
      'build/screenshots';
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      final file = File('$outDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      stdout.writeln('[screenshot] ${file.path} (${bytes.length} bytes)');
      return true;
    },
  );
}
