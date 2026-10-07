import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// WP-3a — where one local replica lives: its database file, its secure-storage
/// key name, and every sidecar (WAL/SHM, maintenance intent, process-liveness
/// lock/instance, cross-isolate lease directory). All sidecars sit beside the
/// database file so removing a replica is removing one directory, and no path is
/// shared between replicas.
class ReplicaLocation {
  const ReplicaLocation({
    required this.directory,
    required this.dbFileName,
    required this.keyName,
  });

  /// The pre-WP-3a shared layout: `<AppSupport>/money_companion.sqlite`, the
  /// `money_companion.db_key` key and its sidecars directly in AppSupport.
  static const String legacyDbFileName = 'money_companion.sqlite';
  static const String legacyKeyName = 'money_companion.db_key';

  static Future<ReplicaLocation> legacy() async => ReplicaLocation(
        directory: (await getApplicationSupportDirectory()).path,
        dbFileName: legacyDbFileName,
        keyName: legacyKeyName,
      );

  final String directory;
  final String dbFileName;
  final String keyName;

  String get dbPath => p.join(directory, dbFileName);
  String get walPath => '$dbPath-wal';
  String get shmPath => '$dbPath-shm';
  String get maintPath => '$dbPath.maint';
  String get plockPath => '$dbPath.plock';
  String get instancePath => '$dbPath.instance';
  String get leaseDir => p.join(directory, 'db_leases');
}
