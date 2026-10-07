/// WP-5 — helpers for the per-mutation operation receipt id.
library;

import 'dart:convert';

const String kPriorOpIdsKey = 'prior_op_ids';
const int _maxPriorOpIds = 8;

/// Operation ids an outbox row carried earlier while possibly on the wire.
List<String> priorOpIdsOf(Map<String, dynamic> payload) =>
    ((payload[kPriorOpIdsKey] as List?) ?? const []).cast<String>();

/// Writes into [payload] the prior-op list of a row that is being edited: the
/// ids already remembered on the old payload, plus [previousOpId] when that
/// operation may already have reached the server. Bounded.
void withPriorOpIds(
  Map<String, dynamic> payload, {
  required String existingPayloadJson,
  required String? previousOpId,
  required bool possiblySent,
}) {
  final old = (jsonDecode(existingPayloadJson) as Map).cast<String, dynamic>();
  final ids = [...priorOpIdsOf(old)];
  if (possiblySent && previousOpId != null && !ids.contains(previousOpId)) {
    ids.add(previousOpId);
  }
  if (ids.isEmpty) return;
  payload[kPriorOpIdsKey] = ids.length > _maxPriorOpIds
      ? ids.sublist(ids.length - _maxPriorOpIds)
      : ids;
}
