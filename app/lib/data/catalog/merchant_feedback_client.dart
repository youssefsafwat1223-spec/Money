import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../db/app_database.dart';
import 'catalog_daos.dart';

/// Posts accumulated anonymous merchant feedback to the Edge Function for
/// admin review. Only normalized merchant strings are sent — never amounts,
/// dates, user IDs, or transaction IDs.
class MerchantFeedbackClient {
  const MerchantFeedbackClient({
    required supabase.SupabaseClient client,
    required AppDatabase database,
    /// C-3 — merchant keywords are derived from the user's own messages, so
    /// this is AI-processing egress. Defaults to DENY: the client is currently
    /// unwired, and whoever wires it must pass consent deliberately rather
    /// than inherit an open default.
    Future<bool> Function()? mayEgress,
  })  : _client = client,
        _db = database,
        _mayEgress = mayEgress ?? _denyEgressByDefault;

  static Future<bool> _denyEgressByDefault() async => false;

  final supabase.SupabaseClient _client;
  final AppDatabase _db;
  final Future<bool> Function() _mayEgress;

  static const _minBatchSize = 5;

  /// Drains `pending_merchant_feedback` and POSTs to `merchant-feedback`
  /// Edge Function if there are [_minBatchSize] or more distinct unknowns.
  Future<void> flushIfReady() async {
    // C-3: checked before the DAO is even read — a refusal must not drain the
    // pending keywords, or a consent-off user would lose them permanently.
    if (!await _mayEgress()) return;
    final dao = PendingMerchantFeedbackDao(_db);
    if (await dao.count() < _minBatchSize) {
      return;
    }
    final keywords = await dao.drainAll();
    if (keywords.isEmpty) return;
    try {
      await _client.functions.invoke(
        'merchant-feedback',
        body: {'keywords': keywords},
      );
    } catch (e) {
      // Silently ignore — keywords are already drained; they'll accumulate again.
      debugPrint('MerchantFeedbackClient: failed to post feedback: $e');
    }
  }
}
