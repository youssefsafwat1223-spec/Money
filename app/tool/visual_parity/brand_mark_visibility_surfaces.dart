// Actual production BrandMark QA, separate from the frozen raw SVG atlas.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_spacing.dart';
import 'package:money_companion/core/theme/app_typography.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

const visualParityBrandMarkVisibilityKeys = ['brandMarkSony', 'brandMarkApple'];
final _events = <String, int>{};
Map<String, int> visualParityBrandMarkVisibilityEvents() =>
    Map.unmodifiable(_events);
void _record(String key) =>
    _events.update(key, (n) => n + 1, ifAbsent: () => 1);

Future<bool> openVisualParityBrandMarkVisibility(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityBrandMarkVisibilityKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('brand_mark_visibility_requires_offline_debug');
  }
  if (!context.mounted) return false;
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('brand_mark_visibility_requires_memory_database');
  }
  final settings = await ref.read(userSettingsProvider.future);
  if (settings.cloudProcessingEnabled ||
      ref.read(remoteMerchantLogosAllowedProvider)) {
    throw StateError('brand_mark_visibility_requires_actual_denied_consent');
  }
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  if (!manifest.listAssets().contains('assets/brands/sony.svg') ||
      !BrandMark.hasBrand('SONY')) {
    throw StateError('brand_mark_visibility_requires_actual_startup_catalog');
  }
  if (!context.mounted) return false;
  final name = key == 'brandMarkSony' ? 'SONY' : 'APPLE';
  _record('${key}Opened');
  unawaited(Navigator.of(context)
      .push<void>(MaterialPageRoute<void>(
          builder: (_) => Scaffold(
              backgroundColor: context.colors.bg,
              appBar: AppBar(title: Text('BrandMark · $name')),
              body: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                RepaintBoundary(
                    key: ValueKey('brandMarkRaster:$name'),
                    child: BrandMark(name: name, size: 96)),
                const SizedBox(height: AppSpacing.s4),
                Text(name,
                    style: AppTypography.title(context.colors.textPrimary)),
                const SizedBox(height: AppSpacing.s2),
                Text('Bundled mark · Remote logos off',
                    style: AppTypography.caption(context.colors.textSecondary)),
              ])))))
      .whenComplete(() => _record('${key}Closed')));
  return true;
}
