import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'supabase_config.dart';

class MetricsClient {
  MetricsClient({supabase.SupabaseClient? client}) : _client = client;

  final supabase.SupabaseClient? _client;

  Future<void> logEvent(String key, {String? dimension}) async {
    if (!SupabaseConfig.isConfigured) return;
    final client = _client ?? supabase.Supabase.instance.client;
    if (client.auth.currentUser == null) return;
    await client.from('metrics').insert({
      'metric_key': key,
      if (dimension != null) 'dimension': dimension,
    });
  }
}
