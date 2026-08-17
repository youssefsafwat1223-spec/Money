import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lgr;

import '../mali_tokens.dart';

/// MaliGlass ADVANCED SHADER TIER — the ONLY production boundary allowed to
/// import `package:liquid_glass_renderer`. Everything else in the app talks
/// to [MaliGlass]; the package is an internal implementation detail
/// (enforced by test/core/theme/widgets/glass_import_guard_test.dart).
///
/// Package role (approved scope): refractive rendering for the pilot
/// surfaces ONLY — the Flutter fallback bottom navigation and the
/// Transactions pinned strip. Qirsh keeps ownership of: theme tokens,
/// accessibility policy (high contrast, reduce motion, semantics, tap
/// targets), platform selection (the native iOS 26 nav path is untouched),
/// fallback policy, and interaction feel. `Glassify` is BANNED from
/// production (experimental; SkSL precompile error observed in the spike) —
/// gallery/research only.
///
/// Layer ownership (#6 of the acceptance brief):
/// - The pilot has no screen with multiple advanced shapes in one region
///   except the pinned strip's tab capsules. So:
///   * Single surfaces (the nav bar) render as [lgr.LiquidGlass.withOwnLayer]
///     — one shape, one layer, smallest possible boundary.
///   * The strip's capsules share ONE [lgr.LiquidGlassLayer] provided by
///     [MaliGlassRegion] placed at the strip (region = the pinned strip, not
///     the app, not per-control).
/// - Lifecycle: a region's layer lives exactly as long as the region widget;
///   own-layers live with their surface. Nothing is global.
/// - Rebuild boundary: [MaliGlassRegion] passes its child through untouched
///   when disabled/unsupported, and the layer only repaints when its shapes
///   or the backdrop behind the region change — children OUTSIDE the region
///   are never wrapped and cannot be repainted by it.
/// TEMPORARY rollout safety gate: the package has open Android rendering
/// issues and NO real-device evidence yet, so Android production surfaces
/// must resolve to Qirsh frost even where shader filters are technically
/// supported. Flip only after the device gate in
/// docs/LIQUID_GLASS_PACKAGE.md passes. This is a rollout hold, not a
/// package rejection.
const bool kAndroidAdvancedRefractionEnabled = false;

/// Platform half of the advanced-tier gate. Uses [defaultTargetPlatform] so
/// tests can simulate platforms via `debugDefaultTargetPlatformOverride`.
/// macOS stays allowed as the desktop/Impeller verification bench.
bool get advancedTierAllowedOnPlatform {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return kAndroidAdvancedRefractionEnabled;
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      return false;
  }
}

enum GlassTier {
  /// Native UIGlassEffect platform view. NOT selected by generic MaliGlass:
  /// native ownership belongs to explicit native hosts only (today: the
  /// pre-existing iOS 26 bottom-navigation host outside MaliGlass). The
  /// tier exists in the resolver so an explicit host can declare itself via
  /// [resolveGlassTier]'s `nativeGlassActive` — generic surfaces always
  /// pass false, regardless of OS version.
  native,

  /// Package-backed refraction (pilot surfaces only).
  advanced,

  /// Qirsh frost (blur + saturation + token fill) — the safe default.
  frost,

  /// Opaque token surface (high contrast).
  opaque,
}

/// Pure decision layer — unit-tested; keeps package selection deterministic
/// and crash-free. The package must NEVER be reached when unsupported: the
/// answer is Qirsh frost, not an assertion, crash, or blank widget.
GlassTier resolveGlassTier({
  required bool advancedRequested,
  required bool shaderSupported,
  required bool platformAllowed,
  required bool highContrast,
  required bool nativeGlassActive,
}) {
  if (highContrast) return GlassTier.opaque;
  if (nativeGlassActive) return GlassTier.native;
  if (advancedRequested && shaderSupported && platformAllowed) {
    return GlassTier.advanced;
  }
  return GlassTier.frost;
}

/// Test hook: forces the capability answer (null = use the real runtime).
@visibleForTesting
bool? debugAdvancedShaderOverride;

/// The actual runtime capability signal the package requires (Impeller's
/// shader image filters; never true on web).
bool get advancedShaderSupported {
  final forced = debugAdvancedShaderOverride;
  if (forced != null) return forced;
  return !kIsWeb && ui.ImageFilter.isShaderFilterSupported;
}

/// Restrained, token-driven settings — the package's demo defaults are NOT
/// the product design system. Premium, not shader-demo: subtle thickness,
/// our saturation values, a faint token tint, near-zero chromatic fringe.
lgr.LiquidGlassSettings _settingsFor(MaliTokens t, {required bool isDark}) {
  return lgr.LiquidGlassSettings(
    thickness: 18,
    blur: 6,
    saturation: isDark ? 1.30 : 1.15,
    glassColor: t.glassFillTop.withValues(alpha: isDark ? 0.06 : 0.16),
    lightIntensity: 0.4,
  );
}

class _MaliGlassRegionScope extends InheritedWidget {
  const _MaliGlassRegionScope({required super.child});

  @override
  bool updateShouldNotify(_MaliGlassRegionScope oldWidget) => false;
}

/// One shared render pass for every advanced MaliGlass surface inside
/// [child]. Place it at the smallest useful visual region (e.g. a pinned
/// strip) — never around the whole app. When the advanced tier is
/// unavailable this is a passthrough and costs nothing.
class MaliGlassRegion extends StatelessWidget {
  const MaliGlassRegion({super.key, required this.child});

  final Widget child;

  static bool isActiveIn(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MaliGlassRegionScope>() !=
      null;

  @override
  Widget build(BuildContext context) {
    if (!advancedShaderSupported || !advancedTierAllowedOnPlatform) {
      return child;
    }
    final t = MaliTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return lgr.LiquidGlassLayer(
      settings: _settingsFor(t, isDark: isDark),
      child: _MaliGlassRegionScope(child: child),
    );
  }
}

/// Builds the advanced (package-backed) surface for MaliGlass. Callers must
/// have already resolved [GlassTier.advanced] via [resolveGlassTier].
Widget buildAdvancedGlassSurface({
  required BuildContext context,
  required double cornerRadius,
  required bool isDark,
  required Widget child,
}) {
  final shape = lgr.LiquidRoundedSuperellipse(borderRadius: cornerRadius);
  if (MaliGlassRegion.isActiveIn(context)) {
    return lgr.LiquidGlass(
      shape: shape,
      glassContainsChild: false,
      child: child,
    );
  }
  final t = MaliTokens.of(context);
  return lgr.LiquidGlass.withOwnLayer(
    shape: shape,
    settings: _settingsFor(t, isDark: isDark),
    glassContainsChild: false,
    child: child,
  );
}
