import 'package:flutter/widgets.dart';

import '../../core/data_portability/data_portability_models.dart';
import '../../core/utils/l10n_ext.dart';

/// Renders an import/export failure in the reader's language.
///
/// The exception carries an Arabic `message` for logs and for any throw site
/// that has no code yet. This prefers the localized rendering when a code is
/// present, and falls back to that message otherwise — so a missed site shows
/// Arabic, which is visible, rather than showing nothing.
String dataPortabilityMessage(BuildContext context, DataPortabilityException e) {
  final code = e.code;
  if (code == null) return e.message;
  final l = context.l10n;
  return switch (code) {
    DataPortabilityError.csvTooLarge => l.dpeCsvTooLarge,
    DataPortabilityError.csvEmpty => l.dpeCsvEmpty,
    DataPortabilityError.csvTooManyRows => l.dpeCsvTooManyRows,
    DataPortabilityError.csvBadHeaders => l.dpeCsvBadHeaders,
    DataPortabilityError.csvDuplicateColumns => l.dpeCsvDuplicateColumns,
    DataPortabilityError.fileTooLarge => l.dpeFileTooLarge,
    DataPortabilityError.zipInvalid => l.dpeZipInvalid,
    DataPortabilityError.pickCsvOrZip => l.dpePickCsvOrZip,
    DataPortabilityError.fixErrorsFirst => l.dpeFixErrorsFirst,
    DataPortabilityError.externalCsvMergeOnly => l.dpeExternalCsvMergeOnly,
    DataPortabilityError.replaceUnavailableMixed => l.dpeReplaceUnavailableMixed,
    DataPortabilityError.replaceUnavailableCloud => l.dpeReplaceUnavailableCloud,
    DataPortabilityError.reselectFile => l.dpeReselectFile,
    DataPortabilityError.csvMappingIncomplete => l.dpeCsvMappingIncomplete,
    DataPortabilityError.exportTooLarge => l.dpeExportTooLarge,
    DataPortabilityError.packageAlreadyImported => l.dpePackageAlreadyImported,
    DataPortabilityError.foreignPairRequired => l.dpeForeignPairRequired,
    DataPortabilityError.unsupportedTable => l.dpeUnsupportedTable(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.otherCategoryMissing => l.dpeOtherCategoryMissing,
    DataPortabilityError.missingValue => l.dpeMissingValue(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.invalidCurrencyCode => l.dpeInvalidCurrencyCode(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.invalidMinorAmount => l.dpeInvalidMinorAmount(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.invalidAmountLegacy => l.dpeInvalidAmount(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.invalidAmount => l.dpeInvalidAmount(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.invalidDate => l.dpeInvalidDate(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.exportFileMissing => l.dpeExportFileMissing(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.zipTooLarge => l.dpeZipTooLarge,
    DataPortabilityError.packageUnsafePath => l.dpePackageUnsafePath,
    DataPortabilityError.packageInflatedTooLarge => l.dpePackageInflatedTooLarge,
    DataPortabilityError.entryUnreadable => l.dpeEntryUnreadable(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.entrySizeMismatch => l.dpeEntrySizeMismatch(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.manifestMissing => l.dpeManifestMissing,
    DataPortabilityError.manifestInvalid => l.dpeManifestInvalid,
    DataPortabilityError.notAQirshExport => l.dpeNotAQirshExport,
    DataPortabilityError.newerVersion => l.dpeNewerVersion,
    DataPortabilityError.unsupportedVersion => l.dpeUnsupportedVersion,
    DataPortabilityError.packageMetaIncomplete => l.dpePackageMetaIncomplete,
    DataPortabilityError.packageEntryMissing => l.dpePackageEntryMissing(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.integrityCheckFailed => l.dpeIntegrityCheckFailed(e.args.isEmpty ? "" : e.args.first),
    DataPortabilityError.packageTooManyRows => l.dpePackageTooManyRows,
  };
}
