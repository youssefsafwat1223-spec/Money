// Offline simulator-only negative storage transport. Never imported by lib/.
// Real AppSession and public Brand: no identity, welcome-success or consent fake.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// Pinned plugin public test boundary, only in this separate debug tool.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/features/onboarding/brand_screen.dart';

final _events = <String, int>{};
Map<String, int> visualParityBrandContinueFailureEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (v) => v + 1, ifAbsent: () => 1);
_ReviewState? _active;
bool _opening = false;

void releaseVisualParityBrandContinueFailure() => _active?.transport.release();

Future<String> _allSql(AppDatabase db) async {
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  return jsonEncode({
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid',
              )
              .get())
          .map((r) => r.data)
          .toList(),
  });
}

Future<Map<String, Object?>> visualParityBrandContinueFailureReadback() async {
  final active = _active;
  if (active == null) return {'active': false};
  return {
    'active': true,
    'allSqlUnchanged':
        await _allSql(active.widget.db) == active.widget.sqlBefore,
    'welcomeSeen': AppSession.instance.hasSeenWelcomeManifesto,
    'welcomeMarker':
        await active.transport.read(key: 'welcome_manifesto_seen', options: {}),
    'attempts': active.transport.attempts,
    'writesLanded': 0,
  };
}

class _FailureTransport extends TestFlutterSecureStoragePlatform {
  _FailureTransport() : super({});
  final gate = Completer<void>();
  int attempts = 0;
  void release() {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<void> write(
      {required String key,
      required String value,
      required Map<String, String> options}) async {
    if (key != 'welcome_manifesto_seen' || value != '1') {
      _event('forbidden');
      throw StateError('unexpected_brand_preview_write');
    }
    attempts++;
    _event('admitted');
    await gate.future;
    _event('rejected');
    throw PlatformException(code: 'qa_brand_storage_failure');
  }

  @override
  Future<void> delete(
      {required String key, required Map<String, String> options}) async {
    _event('forbidden');
    throw StateError('unexpected_brand_preview_delete');
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _event('forbidden');
    throw StateError('unexpected_brand_preview_delete_all');
  }
}

Future<bool> openVisualParityBrandContinueFailure(
    BuildContext context, WidgetRef ref) async {
  if (!kDebugMode ||
      SupabaseConfig.isConfigured ||
      _active != null ||
      _opening) {
    throw StateError('brand_preview_requires_exclusive_offline_debug');
  }
  if (AppSession.instance.hasSeenWelcomeManifesto) {
    throw StateError('brand_preview_requires_actual_unseen_welcome');
  }
  _opening = true;
  try {
    final db = ref.read(appDatabaseProvider);
    final attached = await db.customSelect('PRAGMA database_list').get();
    if (!attached.any((r) =>
        r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
      throw StateError('brand_preview_requires_memory');
    }
    final before = await _allSql(db);
    if (!context.mounted) return false;
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => _Review(db, before),
    )));
    return true;
  } finally {
    _opening = false;
  }
}

class _Review extends StatefulWidget {
  const _Review(this.db, this.sqlBefore);
  final AppDatabase db;
  final String sqlBefore;
  @override
  State<_Review> createState() => _ReviewState();
}

class _ReviewState extends State<_Review> {
  late final FlutterSecureStoragePlatform previous;
  final transport = _FailureTransport();
  @override
  void initState() {
    super.initState();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = transport;
    _active = this;
    _event('opened');
  }

  @override
  void dispose() {
    transport.release();
    if (identical(FlutterSecureStoragePlatform.instance, transport)) {
      FlutterSecureStoragePlatform.instance = previous;
    }
    if (identical(_active, this)) _active = null;
    _event('closed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const OnboardingBrandScreen();
}
