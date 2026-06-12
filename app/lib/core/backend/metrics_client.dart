import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'supabase_config.dart';

class MetricsClient {
  MetricsClient({supabase.SupabaseClient? client})
      : _client = client ?? supabase.Supabase.instance.client;

  final supabase.SupabaseClient _client;

  Future<void> logEvent(String key, {String? dimension}) async {
    if (!SupabaseConfig.isConfigured) return;
    if (_client.auth.currentUser == null) return;
    await _client.from('metrics').insert({
      'metric_key': key,
      if (dimension != null) 'dimension': dimension,
    });
  }
}
