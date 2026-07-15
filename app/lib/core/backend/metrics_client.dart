import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'supabase_config.dart';

class MetricsClient {
  MetricsClient({supabase.SupabaseClient? client}) : _client = client;

  final supabase.SupabaseClient? _client;

  Future<void> logEvent(String key, {String? dimension}) async {
    // isConfigured only matters when falling back to the global singleton —
    // an explicitly-injected client (tests) is usable regardless of it.
    if (_client == null && !SupabaseConfig.isConfigured) return;
    final client = _client ?? supabase.Supabase.instance.client;
    if (client.auth.currentUser == null) return;
    // currentUser reflects a locally-cached session and can be non-null even
    // when the underlying token is stale/expired (e.g. a failed silent
    // refresh on cold start) — the insert then reaches Postgres as `anon`
    // and RLS (metrics insert is `TO authenticated` only) rejects it.
    // Metrics are best-effort telemetry and must never be able to block a
    // caller — in particular this is awaited directly from app bootstrap,
    // where an uncaught exception here previously stopped runApp() from ever
    // being called, hanging every cold start with an invalid stored session.
    try {
      await client.from('metrics').insert({
        'metric_key': key,
        if (dimension != null) 'dimension': dimension,
      });
    } catch (_) {
      // Best-effort — never propagate a metrics failure to the caller.
    }
  }
}
