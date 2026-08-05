// MALI-065n — shared, app-wide managed export lifecycle.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'managed_export_store.dart';

/// The single [ManagedExportStore] used by every export surface (reports, CSV,
/// full-data package). Stateless on-disk, so a shared instance is sufficient.
final managedExportStoreProvider =
    Provider<ManagedExportStore>((ref) => ManagedExportStore());
