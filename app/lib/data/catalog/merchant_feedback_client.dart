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
  })  : _client = client,
        _db = database;

  final supabase.SupabaseClient _client;
  final AppDatabase _db;

  static const _minBatchSize = 5;

  /// Drains `pending_merchant_feedback` and POSTs to `merchant-feedback`
  /// Edge Function if there are [_minBatchSize] or more distinct unknowns.
  Future<void> flushIfReady() async {
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
