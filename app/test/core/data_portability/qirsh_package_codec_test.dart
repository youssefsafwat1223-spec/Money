import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/portable_csv.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';

void main() {
  Map<String, Uint8List> files() => {
        for (final table in qirshPackageTables)
          '$table.csv': encodePortableCsv(
            const ['record_id', 'name'],
            [
              ['$table-1', table],
            ],
          ),
      };

  test('round-trips a complete Qirsh package', () {
    final bytes = encodeQirshPackage(
      packageId: 'package-1',
      exportedAt: DateTime.utc(2026, 7, 18),
      csvFiles: files(),
    );
    final decoded = decodeQirshPackage(bytes);
    expect(decoded.packageId, 'package-1');
    expect(decoded.totalRows, qirshPackageTables.length);
    expect(decoded.tables['accounts']!.rows.single['record_id'], 'accounts-1');
  });

  test('rejects unexpected and traversal entries', () {
    final archive = Archive()
      ..addFile(ArchiveFile('../secret.txt', 1, const [1]));
    final bytes = ZipEncoder().encodeBytes(archive);
    expect(() => decodeQirshPackage(bytes), throwsA(isA<Exception>()));
  });

  test('rejects a package when a CSV checksum is modified', () {
    final encoded = encodeQirshPackage(
      packageId: 'package-2',
      exportedAt: DateTime.utc(2026, 7, 18),
      csvFiles: files(),
    );
    final archive = ZipDecoder().decodeBytes(encoded);
    final changed = Archive();
    for (final entry in archive.files) {
      final content = entry.name == 'accounts.csv'
          ? encodePortableCsv(const [
              'record_id'
            ], const [
              ['changed']
            ])
          : entry.readBytes()!;
      changed.addFile(ArchiveFile(entry.name, content.length, content));
    }
    final tampered = ZipEncoder().encodeBytes(changed);
    expect(() => decodeQirshPackage(tampered), throwsA(isA<Exception>()));
  });

  test('rejects an oversized expanded entry before reading its content', () {
    final encoded = encodeQirshPackage(
      packageId: 'package-bomb',
      exportedAt: DateTime.utc(2026, 7, 18),
      csvFiles: files(),
    );
    final malicious = Uint8List.fromList(encoded);
    const centralDirectorySignature = [0x50, 0x4b, 0x01, 0x02];
    const declaredSize = maxExpandedImportBytes + 1;
    for (var index = 0; index <= malicious.length - 28; index++) {
      if (malicious[index] == centralDirectorySignature[0] &&
          malicious[index + 1] == centralDirectorySignature[1] &&
          malicious[index + 2] == centralDirectorySignature[2] &&
          malicious[index + 3] == centralDirectorySignature[3]) {
        malicious[index + 24] = declaredSize & 0xff;
        malicious[index + 25] = (declaredSize >> 8) & 0xff;
        malicious[index + 26] = (declaredSize >> 16) & 0xff;
        malicious[index + 27] = (declaredSize >> 24) & 0xff;
        break;
      }
    }

    expect(
      () => decodeQirshPackage(malicious),
      throwsA(isA<DataPortabilityException>()),
    );
  });
}
