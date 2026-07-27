import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Drop-in for `maybeWhen(data:, orElse:)` that keeps rendering the last loaded
/// value while the provider is *reloading*, instead of flashing back to
/// `orElse`.
///
/// Riverpod's `maybeWhen`/`when` match the runtime state (`AsyncLoading`) on a
/// reload even when a previous value exists, so a provider that rebuilds on a
/// `dbRevision` tick (account switch, sync write, settings save) momentarily
/// renders its placeholder — the UI flicker. `dataOrWhen` reads `valueOrNull`
/// (which carries the previous value through a reload) and only falls back on a
/// genuine first load with no value yet. Same call shape as `maybeWhen`, so
/// converting a site is just `.maybeWhen(` → `.dataOrWhen(`.
extension AsyncReloadSafe<T> on AsyncValue<T> {
  R dataOrWhen<R>({
    required R Function(T value) data,
    required R Function() orElse,
  }) {
    final value = valueOrNull;
    return value != null ? data(value) : orElse();
  }
}
