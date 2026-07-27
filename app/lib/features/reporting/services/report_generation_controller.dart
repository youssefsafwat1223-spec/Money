import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../data/reporting/report_snapshot_builder.dart';
import '../../../domain/reporting/report_data_snapshot.dart';
import '../../../domain/reporting/report_request.dart';
import '../composition/report_composer.dart';
import '../composition/report_view_model.dart';
import '../pdf/report_fonts.dart';
import '../pdf/report_pdf_renderer.dart';
import '../pdf/report_theme_spec.dart';
import 'report_file_service.dart';

/// Ordered stages of report generation, used for determinate progress.
enum ReportStage {
  idle,
  collecting,
  composing,
  rendering,
  writing,
  ready,
  cancelled,
  failed,
}

/// A progress update: the current [stage] and an overall [fraction] `0..1`.
class ReportProgress {
  const ReportProgress(this.stage, this.fraction);

  final ReportStage stage;
  final double fraction;
}

/// Plain-language error categories for the UI.
enum ReportErrorKind {
  noData,
  fontLoadFailed,
  renderFailed,
  writeFailed,
  cancelled,
  unknown,
}

class ReportGenerationException implements Exception {
  ReportGenerationException(this.kind, {this.cause});

  final ReportErrorKind kind;
  final Object? cause;

  @override
  String toString() => 'ReportGenerationException($kind)';
}

/// Cooperative cancellation token, checked between stages.
class ReportCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// The finished artifact.
class ReportResult {
  const ReportResult({
    required this.file,
    required this.bytes,
    required this.snapshot,
  });

  final File file;
  final Uint8List bytes;
  final ReportDataSnapshot snapshot;
}

/// Orchestrates one report generation across the layers — collect (data) →
/// compose (metrics/view model) → render (PDF bytes) → write (temp file) —
/// with determinate progress, cooperative cancellation, a plain-language error
/// taxonomy, and snapshot caching so a "regenerate with different options" run
/// can skip re-collection.
///
/// Dependency-injected and Riverpod-free, so it is fully testable. Fonts are
/// loaded via an injected loader (the main-isolate `ReportFonts.load` in the
/// app) and passed into the pure renderer.
class ReportGenerationController {
  ReportGenerationController({
    required this.fileService,
    required Future<ReportFontSet> Function() loadFonts,
    Future<ReportFontBytes> Function()? loadFontBytes,
    Future<Uint8List?> Function()? loadLogoBytes,
    ReportSnapshotBuilder? builder,
    ReportSnapshotBuilder Function()? builderFactory,
    this.composer = const ReportComposer(),
    this.renderer = const ReportPdfRenderer(),
    this.theme = const ReportThemeSpec(),
  })  : assert(builder != null || builderFactory != null,
            'Provide a builder or a builderFactory'),
        _builder = builder,
        _builderFactory = builderFactory,
        _loadFonts = loadFonts,
        _loadFontBytes = loadFontBytes,
        _loadLogoBytes = loadLogoBytes;

  final ReportFileService fileService;
  final ReportSnapshotBuilder? _builder;
  final ReportSnapshotBuilder Function()? _builderFactory;
  final ReportComposer composer;
  final ReportPdfRenderer renderer;
  final ReportThemeSpec theme;
  final Future<ReportFontSet> Function() _loadFonts;
  final Future<ReportFontBytes> Function()? _loadFontBytes;
  final Future<Uint8List?> Function()? _loadLogoBytes;

  ReportDataSnapshot? _cachedSnapshot;

  ReportSnapshotBuilder get _resolvedBuilder =>
      _builder ?? _builderFactory!.call();

  /// Generates the report. Emits [ReportProgress] via [onProgress]; throws a
  /// [ReportGenerationException] on cancellation or failure.
  ///
  /// When [reuseSnapshot] is true and a snapshot was previously collected, the
  /// data-collection stage is skipped (used for "change display options and
  /// regenerate" without a second DB pass).
  Future<ReportResult> generate(
    ReportRequest request, {
    void Function(ReportProgress)? onProgress,
    ReportCancelToken? cancel,
    bool reuseSnapshot = false,
  }) async {
    void emit(ReportStage stage, double fraction) =>
        onProgress?.call(ReportProgress(stage, fraction));
    void throwIfCancelled() {
      if (cancel?.isCancelled ?? false) {
        emit(ReportStage.cancelled, 0);
        throw ReportGenerationException(ReportErrorKind.cancelled);
      }
    }

    try {
      // 1 — collect (or reuse cached snapshot).
      ReportDataSnapshot snapshot;
      final cached = _cachedSnapshot;
      if (reuseSnapshot && cached != null) {
        snapshot = cached;
      } else {
        emit(ReportStage.collecting, 0.1);
        snapshot = await _resolvedBuilder.build(request);
        _cachedSnapshot = snapshot;
      }
      throwIfCancelled();

      // 2 — compose (pure).
      emit(ReportStage.composing, 0.45);
      final model = composer.compose(snapshot);
      throwIfCancelled();

      // 3 — render. Load the brand mark on the main isolate; when font bytes
      // are provided, render off the main isolate to keep the UI responsive.
      emit(ReportStage.rendering, 0.6);
      final logoBytes = _loadLogoBytes == null ? null : await _loadLogoBytes();
      final loadBytes = _loadFontBytes;
      final Uint8List bytes;
      if (loadBytes != null) {
        final ReportFontBytes fontBytes;
        try {
          fontBytes = await loadBytes();
        } catch (e) {
          throw ReportGenerationException(ReportErrorKind.fontLoadFailed, cause: e);
        }
        throwIfCancelled();
        try {
          bytes = await _renderInIsolate(model, fontBytes, logoBytes);
        } catch (e) {
          throw ReportGenerationException(ReportErrorKind.renderFailed, cause: e);
        }
      } else {
        final ReportFontSet fonts;
        try {
          fonts = await _loadFonts();
        } catch (e) {
          throw ReportGenerationException(ReportErrorKind.fontLoadFailed, cause: e);
        }
        throwIfCancelled();
        final activeRenderer = logoBytes == null
            ? renderer
            : ReportPdfRenderer(logoBytes: logoBytes);
        try {
          bytes = await activeRenderer.render(
              model: model, fonts: fonts, theme: theme);
        } catch (e) {
          throw ReportGenerationException(ReportErrorKind.renderFailed, cause: e);
        }
      }
      throwIfCancelled();

      // 4 — write temp file.
      emit(ReportStage.writing, 0.9);
      final File file;
      try {
        file = await fileService.writeTemporary(
          bytes,
          fileService.fileName(snapshot.range, snapshot.capturedAt),
        );
      } catch (e) {
        throw ReportGenerationException(ReportErrorKind.writeFailed, cause: e);
      }

      emit(ReportStage.ready, 1);
      return ReportResult(file: file, bytes: bytes, snapshot: snapshot);
    } on ReportGenerationException {
      rethrow;
    } catch (e) {
      emit(ReportStage.failed, 0);
      throw ReportGenerationException(ReportErrorKind.unknown, cause: e);
    }
  }

  /// Renders on a background isolate. Only plain-data (the view model, font
  /// bytes, logo bytes) crosses the boundary; fonts are parsed inside.
  static Future<Uint8List> _renderInIsolate(
    ReportViewModel model,
    ReportFontBytes fontBytes,
    Uint8List? logoBytes,
  ) {
    return Isolate.run(() {
      final fonts = ReportFonts.fontSetFromBytes(fontBytes);
      return ReportPdfRenderer(logoBytes: logoBytes).render(
        model: model,
        fonts: fonts,
        theme: const ReportThemeSpec(),
      );
    });
  }

  /// Clears the cached snapshot (e.g. when the period/scope changes).
  void invalidate() => _cachedSnapshot = null;
}
