import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session/account_scope.dart';

/// Offline local read — thrown when a writer- or cloud-bearing provider is read
/// under a local-read scope. SQLite's read-only connection is the final data
/// boundary; this is the earlier one: such a service is never even built.
class LocalReadWriterDenied implements Exception {
  const LocalReadWriterDenied();
  @override
  String toString() => 'LocalReadWriterDenied: no writer or cloud service '
      'exists under an offline local-read scope.';
}

/// The access mode of the scope this provider graph is built on. The root
/// `ProviderScope` is keyed by the scope generation and overrides this per scope,
/// so it never changes within one graph.
final accountAccessModeProvider =
    Provider<AccountAccessMode>((ref) => AccountAccessMode.writable);

/// A provider that builds a writer, outbox, sync, capture, cloud or notification
/// service. Under a local-read scope it throws [LocalReadWriterDenied] instead of
/// building anything; otherwise it is exactly `Provider<T>(create)`.
Provider<T> writerProvider<T>(T Function(ProviderRef<T> ref) create) =>
    Provider<T>((ref) {
      if (ref.watch(accountAccessModeProvider) == AccountAccessMode.localRead) {
        throw const LocalReadWriterDenied();
      }
      return create(ref);
    });
