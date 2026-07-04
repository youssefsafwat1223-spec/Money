import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'catalog_daos.dart';

/// Safe defaults — used when a flag is missing, inactive, or sync has not run.
/// Every flag key that the app references must appear here.
const Map<String, Object> _defaults = {
  'enable_goals': true,
  'enable_coupons': false,
  'enable_announcements': true,
  'parser_engine_version': 'v1',
  'ledger_dual_write': false,
  'ledger_pull_sync': false,
  'ledger_push_sync': false,
  'smart_inbox_pull_sync': false,
  'planning_accounts_sync': false,
  'planning_budgets_sync': false,
  'planning_subscriptions_sync': false,
  'planning_goals_sync': false,
  'planning_plans_sync': false,
  'capture_direct_ledger_write': false,
};

class FeatureFlagService {
  FeatureFlagService({
    required RemoteFeatureFlagsDao dao,
    required String installId,
  })  : _dao = dao,
        _installId = installId;

  final RemoteFeatureFlagsDao _dao;
  final String _installId;

  // In-memory cache populated by init(). Safe defaults are used until init runs.
  final Map<String, Object> _cache = Map.of(_defaults);

  bool _initialised = false;

  /// Load all flags from Drift and compute rollout buckets.
  /// Must be called after seed/sync. Safe to call multiple times.
  Future<void> init() async {
    try {
      final flags = await _dao.getAllActiveFlags();
      final sha = Sha256();
      final resolved = <String, Object>{};
      for (final flag in flags) {
        final value = await _resolveFlag(flag, sha);
        if (value != null) resolved[flag.key] = value;
      }
      _cache
        ..clear()
        ..addAll(_defaults)
        ..addAll(resolved);
      _initialised = true;
    } catch (e, st) {
      debugPrint('FeatureFlagService.init failed: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  bool get isInitialised => _initialised;

  bool getBool(String key) {
    final v = _cache[key];
    if (v is bool) return v;
    return _defaults[key] is bool ? _defaults[key] as bool : false;
  }

  String getString(String key) {
    final v = _cache[key];
    if (v is String) return v;
    return _defaults[key] is String ? _defaults[key] as String : '';
  }

  int getInt(String key) {
    final v = _cache[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return _defaults[key] is num ? (_defaults[key] as num).toInt() : 0;
  }

  Object? getJson(String key) {
    return _cache[key] ?? _defaults[key];
  }

  Future<Object?> _resolveFlag(RemoteFeatureFlag flag, Sha256 sha) async {
    if (!flag.isActive) return null;

    final bool inRollout;
    if (flag.rolloutPercent >= 100) {
      inRollout = true;
    } else if (flag.rolloutPercent <= 0) {
      inRollout = false;
    } else {
      // SHA-256("$installId:$key") → first 2 bytes → uint16 % 100
      final hash = await sha.hash(
        utf8.encode('$_installId:${flag.key}'),
      );
      final bucket = ((hash.bytes[0] << 8) | hash.bytes[1]) % 100;
      inRollout = bucket < flag.rolloutPercent;
    }

    if (!inRollout) return null;

    switch (flag.valueType) {
      case 'boolean':
        return flag.value.toLowerCase() == 'true';
      case 'number':
        return num.tryParse(flag.value);
      case 'string':
        return flag.value;
      case 'json':
        try {
          return jsonDecode(flag.value) as Object?;
        } catch (_) {
          return null;
        }
      default:
        return null;
    }
  }
}
