// Raw bundled SVG QA only. Does not exercise BrandMark mapping or remote logos.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_spacing.dart';
import 'package:money_companion/core/theme/app_typography.dart';

const visualParityBrandAssetAtlasKeys = [
  'brandAssetAtlas0',
  'brandAssetAtlas1',
  'brandAssetAtlas2',
  'brandAssetAtlas3',
  'brandAssetAtlas4',
  'brandAssetAtlas5',
];
final _events = <String, int>{};
final _decodeErrors = <String, String>{};
Map<String, int> visualParityBrandAssetAtlasEvents() =>
    Map.unmodifiable(_events);
Map<String, String> visualParityBrandAssetAtlasErrors() =>
    Map.unmodifiable(_decodeErrors);
void _record(String key) =>
    _events.update(key, (n) => n + 1, ifAbsent: () => 1);

Future<List<String>> visualParityBrandAssetPaths() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final paths = manifest
      .listAssets()
      .where((path) => RegExp(r'^assets/brands/[^/]+\.svg$').hasMatch(path))
      .toList()
    ..sort();
  return List.unmodifiable(paths);
}

Future<bool> openVisualParityBrandAssetAtlas(
    BuildContext context, WidgetRef ref, String key) async {
  final page = visualParityBrandAssetAtlasKeys.indexOf(key);
  if (page < 0) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('brand_atlas_requires_offline_debug');
  }
  if (!context.mounted) return false;
  final parent = ref.read(appDatabaseProvider);
  final databases = await parent.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('brand_atlas_requires_memory_database');
  }
  final paths = await visualParityBrandAssetPaths();
  if ((paths.length / 24).ceil() != visualParityBrandAssetAtlasKeys.length) {
    throw StateError('brand_atlas_manifest_page_count_changed');
  }
  if (!context.mounted) return false;
  final start = page * 24;
  final selected = paths.skip(start).take(24).toList(growable: false);
  _record('${key}Opened');
  unawaited(Navigator.of(context)
      .push<void>(MaterialPageRoute<void>(
          builder: (_) => _AtlasPage(
              page: page, start: start, total: paths.length, paths: selected)))
      .whenComplete(() => _record('${key}Closed')));
  return true;
}

class _AtlasPage extends StatelessWidget {
  const _AtlasPage(
      {required this.page,
      required this.start,
      required this.total,
      required this.paths});
  final int page;
  final int start;
  final int total;
  final List<String> paths;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.colors.bg,
        appBar: AppBar(
            title: Text('Brand assets ${page + 1}/6',
                style: AppTypography.title(context.colors.textPrimary))),
        body: SingleChildScrollView(
            child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${start + 1}–${start + paths.length} / $total',
                style: AppTypography.caption(context.colors.textSecondary)),
            const SizedBox(height: AppSpacing.s3),
            LayoutBuilder(builder: (context, constraints) {
              final tileWidth = ((constraints.maxWidth - AppSpacing.s2 * 3) / 4)
                  .floorToDouble();
              return Wrap(
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s2,
                  children: [
                    for (final path in paths)
                      Container(
                        key: ValueKey('brandAtlasTile:$path'),
                        width: tileWidth,
                        padding: const EdgeInsets.all(AppSpacing.s2),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: context.colors.border)),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          SvgPicture.asset(path,
                              width: 56,
                              height: 56,
                              fit: BoxFit.contain,
                              semanticsLabel: path.split('/').last,
                              errorBuilder: (context, error, stack) {
                            _decodeErrors[path] = error.toString();
                            return const SizedBox(
                                width: 56,
                                height: 56,
                                child: Icon(Icons.broken_image_outlined,
                                    color: Colors.red));
                          }),
                          const SizedBox(height: AppSpacing.s2),
                          Text(path.split('/').last,
                              textAlign: TextAlign.center,
                              textDirection: TextDirection.ltr,
                              style: AppTypography.caption(
                                  const Color(0xFF0C1330))),
                        ]),
                      ),
                  ]);
            }),
          ]),
        )),
      );
}
