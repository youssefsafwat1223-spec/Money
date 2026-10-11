import 'dart:convert';

import '../../../core/security/secure_storage_options.dart';
import '../../../core/session/app_session.dart';
import '../../../data/db/app_database.dart';
import 'native_capture_bridge.dart';

/// Immutable provenance. Missing provenance is retained locally, never adopted.
class NotificationLogOrigin {
  const NotificationLogOrigin(this.uid, this.localGeneration,
      {this.nativeGeneration, required this.isCurrent, this.validate});

  static const payloadKey = '_notification_origin';
  final String uid;
  final String localGeneration;
  final int? nativeGeneration;
  final bool Function() isCurrent;
  final Future<bool> Function()? validate;
  Future<bool> holds() async {
    if (!isCurrent()) return false;
    final valid = await (validate?.call() ?? Future.value(true));
    return valid && isCurrent();
  }

  Map<String, Object> payload(String kind) => {
        'kind': kind,
        'uid': uid,
        'generation': kind == 'native' ? nativeGeneration! : localGeneration,
      };

  bool owns(String encoded) {
    try {
      final origin = (jsonDecode(encoded) as Map)[payloadKey];
      if (origin is! Map || origin['uid'] != uid) return false;
      return origin['kind'] == 'local'
          ? origin['generation'] == localGeneration
          : origin['kind'] == 'native' && nativeGeneration != null &&
              origin['generation'] == nativeGeneration;
    } catch (_) {
      return false;
    }
  }
}

/// Reads existing ownership only; never creates or renews admission/generation.
Future<NotificationLogOrigin?> readNotificationLogOrigin(
  AppDatabase db, {
  bool Function()? isCurrentScope,
}) async {
  final authority = AppSession.instance.captureLocalWorkAuthority();
  if (authority == null) return null;
  bool live() => authority.isCurrent &&
      db.lifecycleState == DatabaseLifecycleState.open &&
      (isCurrentScope?.call() ?? true);
  if (!live()) return null;
  final uid = await AppSession.instance.readLocalDataOwnerUid();
  if (!live() || uid != authority.uid) return null;
  final generation = await SecureStorageOptions.storage
      .read(key: 'local_data_owner_generation');
  if (!live() || generation == null || generation.isEmpty) return null;
  final native = await NativeCaptureBridge.getCaptureOwner();
  if (!live()) return null;
  return NotificationLogOrigin(uid!, generation,
      nativeGeneration: native?.uid == uid ? native?.generation : null,
      isCurrent: live,
      validate: () async {
        if (!live()) return false;
        final currentUid = await AppSession.instance.readLocalDataOwnerUid();
        if (!live() || currentUid != uid) return false;
        final currentGeneration = await SecureStorageOptions.storage
            .read(key: 'local_data_owner_generation');
        if (!live() || currentGeneration != generation) return false;
        if (native?.uid == uid) {
          final currentNative = await NativeCaptureBridge.getCaptureOwner();
          if (!live() || currentNative?.uid != uid ||
              currentNative?.generation != native?.generation) {
            return false;
          }
        }
        return live();
      });
}
