import 'dart:async';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

/// In-memory secure storage that RECORDS every write/delete (attempted effects,
/// not just final state) and can pause a chosen operation on a gate, so a test
/// can interleave a callback at an exact point without sleeps.
///
/// F2 evidence must be about ATTEMPTS: a recreated marker or key that a later
/// step deletes again would be invisible to a final-state assertion.
class RecordingSecureStorage extends TestFlutterSecureStoragePlatform {
  RecordingSecureStorage([Map<String, String>? initial])
      : super(initial ?? <String, String>{});

  /// Every `write` that LANDED, in order, as `key=value`.
  final List<String> writes = [];
  final List<String> deletes = [];

  /// Every write/delete ATTEMPT, recorded when the call is made (before any gate
  /// holds it): `write:key=value` / `delete:key`.
  final List<String> attempts = [];

  /// Called before each operation (`read|write|delete`, key); a test returns a
  /// Future to hold the operation.
  Future<void> Function(String op, String key)? gate;

  /// Holds the next operation matching [match] until [Hold.release] completes.
  /// One-shot. [Hold.reached] completes when the operation is being held.
  Hold holdOnce(bool Function(String op, String key) match) {
    final hold = Hold();
    final previous = gate;
    gate = (op, key) async {
      if (!hold.used && match(op, key)) {
        hold.used = true;
        hold.reached.complete();
        await hold.release.future;
        return;
      }
      await previous?.call(op, key);
    };
    return hold;
  }

  /// Installs this instance as the process-wide platform.
  RecordingSecureStorage install() {
    FlutterSecureStoragePlatform.instance = this;
    return this;
  }

  List<String> writesTo(String keyPrefix) =>
      writes.where((w) => w.startsWith(keyPrefix)).toList();
  List<String> attemptsTo(String keyPrefix) =>
      attempts.where((a) => a.startsWith('write:$keyPrefix')).toList();

  @override
  Future<String?> read(
      {required String key, required Map<String, String> options}) async {
    await gate?.call('read', key);
    return super.read(key: key, options: options);
  }

  @override
  Future<void> write(
      {required String key,
      required String value,
      required Map<String, String> options}) async {
    attempts.add('write:$key=$value');
    await gate?.call('write', key);
    writes.add('$key=$value');
    return super.write(key: key, value: value, options: options);
  }

  @override
  Future<void> delete(
      {required String key, required Map<String, String> options}) async {
    attempts.add('delete:$key');
    await gate?.call('delete', key);
    deletes.add(key);
    return super.delete(key: key, options: options);
  }
}

/// One held operation: [reached] when it is being held, [release] to let it go.
class Hold {
  final reached = Completer<void>();
  final release = Completer<void>();
  bool used = false;
}
