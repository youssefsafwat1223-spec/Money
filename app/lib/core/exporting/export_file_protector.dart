// MALI-065n — platform file-protection for managed export temp files.
//
// On iOS, a plaintext export sitting in the temp directory is readable if the
// device is later compromised while locked, and could be swept into an iCloud/
// iTunes backup. This channel asks the native side to (a) apply
// NSFileProtectionComplete (the file is unreadable while the device is locked)
// and (b) mark the file excluded from platform backup. On Android the app's
// files are already private, encrypted at rest (FBE), and excluded from backup
// (allowBackup=false, MALI-033), so the platform handler is a no-op there.
library;

import 'package:flutter/services.dart';

/// Applies platform at-rest protection to a file path. Best-effort by contract:
/// an export must never fail because protection could not be applied.
abstract class ExportFileProtector {
  Future<void> protect(String path);
}

/// Talks to the native `mali/export_protection` channel.
class PlatformExportFileProtector implements ExportFileProtector {
  const PlatformExportFileProtector();

  static const MethodChannel _channel = MethodChannel('mali/export_protection');

  @override
  Future<void> protect(String path) async {
    try {
      await _channel.invokeMethod<void>('protect', <String, Object?>{
        'path': path,
      });
    } catch (_) {
      // Missing handler (tests / unsupported platform) or a native failure must
      // not block the export. Android relies on FBE + allowBackup=false.
    }
  }
}

/// No-op protector for tests and platforms without a handler.
class NoopExportFileProtector implements ExportFileProtector {
  const NoopExportFileProtector();

  @override
  Future<void> protect(String path) async {}
}
