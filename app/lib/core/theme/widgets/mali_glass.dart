import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_motion.dart';
import '../app_spacing.dart';
import '../mali_tokens.dart';
import 'liquid_glass/shader_utils.dart';
import 'mali_glass_advanced.dart';

/// MaliGlass — the Liquid Glass material (pilot).
///
/// A real backdrop-blurred glass surface inspired by Apple's Liquid Glass and
/// the `liquid-glass-react` reference, built as a Calm Capital primitive:
/// bounded backdrop blur + restrained saturation, a mode-aware token fill
/// ([MaliTokens.glassFillTop]/[MaliTokens.glassFillBottom]), a 1px rim
/// ([MaliTokens.glassStroke]) and a top specular edge ([MaliTokens.glassSheen]).
///
/// Tiers:
///  1. **Static** — the default. Blur + saturation + fill + rim + sheen.
///  2. **Interactive** — automatic when [onTap] is set: restrained press scale
///     (0.97, matching `AppButton`) and a soft press highlight. Fully static
///     under reduce-motion (the pressed state still shows, without animation).
///  3. **Refractive** — SDF edge refraction with edge-only chromatic
///     aberration via `ImageFilter.shader` (profile ported from
///     rdev/liquid-glass-react: edge-band lens, per-channel displacement
///     spread, light blur + strong saturation so the bend stays crisp).
///     ON BY DEFAULT on capable devices for every variant except `sheet`
///     ([refractive] null = auto; pass false to force Tier 2, true to force
///     the attempt). Requires Impeller; silently degrades to Tier 2 when
///     `ui.ImageFilter.isShaderFilterSupported` is false, while the fragment
///     program loads, or if loading fails. The program is loaded lazily on
///     first refractive use — never at app startup.
///
/// Accessibility: under `MediaQuery.highContrast` the surface drops blur and
/// translucency entirely and renders an opaque token fill with a full-contrast
/// border, so legibility never depends on what is behind the glass.
///
/// Design-system rules (see the placement report): glass is *chrome* material —
/// navigation, pinned strips, small floating controls. Never inside repeating
/// scrolling list items, never under primary financial values.
/// `headerAction` is the on-accent special case: circular actions sitting on
/// the opaque blue gradient headers. Blurring a flat gradient is invisible,
/// so this variant skips the BackdropFilter entirely (zero GPU readback) and
/// uses mode-invariant white-on-blue fills — the material identity comes from
/// the rim, sheen, and press response.
enum MaliGlassVariant { pill, card, navigation, sheet, headerAction }

class MaliGlass extends StatefulWidget {
  const MaliGlass({
    super.key,
    required this.child,
    this.variant = MaliGlassVariant.card,
    this.radius,
    this.padding,
    this.onTap,
    this.enabled = true,
    this.refractive,
    this.advancedRefraction = false,
  });

  final Widget child;
  final MaliGlassVariant variant;

  /// Corner radius override; defaults per variant (pill 999 / card 28 /
  /// nav 26 / sheet top-only 28). The override is uniform — sheet keeps its
  /// top-only shape only when this is null.
  final double? radius;

  /// Content padding override; defaults per variant.
  final EdgeInsetsGeometry? padding;

  /// When set (and [enabled]), the surface becomes Tier 2 interactive: button
  /// semantics, focus/keyboard activation via [InkWell], press scale +
  /// highlight, and a ≥44px minimum touch target.
  final VoidCallback? onTap;
  final bool enabled;

  /// Tier 3 control: null = auto (on for every variant except `sheet` when
  /// the device supports shader image filters), true/false to force.
  final bool? refractive;

  /// ADVANCED SHADER TIER (liquid_glass_renderer behind the Qirsh adapter —
  /// see mali_glass_advanced.dart). Pilot-gated: set true ONLY on the
  /// approved pilot surfaces (Flutter fallback bottom nav, Transactions
  /// pinned strip capsules). Falls back to Qirsh frost when the runtime has
  /// no shader support; high contrast always wins with the opaque surface.
  final bool advancedRefraction;

  @override
  State<MaliGlass> createState() => _MaliGlassState();
}

class _MaliGlassState extends State<MaliGlass> {
  // The fragment program is cached process-wide after the first refractive
  // surface loads it; each State owns its own FragmentShader instance (uniform
  // values are per-shader, so instances must not be shared across widgets).
  static ui.FragmentProgram? _refractionProgram;
  static Future<ui.FragmentProgram>? _refractionFuture;
  static ui.Image? _displacementMap;
  static Future<ui.Image>? _displacementMapFuture;

  // rdev/liquid-glass-react `LiquidGlass` defaults, verbatim:
  //   displacementScale: 70, aberrationIntensity: 2,
  //   backdropFilter: blur(4 + blurAmount(0.0625) * 32 = 6px) saturate(140%).
  // 100 = the reference demo page's slider default (the look Youssef wants);
  // the library's own default is 70.
  static const double _displacementScale = 100.0;
  static const double _aberrationIntensity = 2.0;
  static const double _refractiveBlurSigma = 6.0;
  static const double _refractiveSaturation = 1.40;
  // Reference boxShadow: 0px 12px 40px rgba(0, 0, 0, 0.25).
  static const List<BoxShadow> _refractiveShadow = [
    BoxShadow(
      color: Color(0x40000000),
      blurRadius: 40,
      offset: Offset(0, 12),
    ),
  ];
  // Reference generates the map at the element's size; the lens shape lives
  // in normalized UV (SDF constants 0.3/0.2/0.6), so one canonical map
  // stretched across the element (its feImage does the same) suffices.
  static const int _mapSize = 256;

  ui.FragmentShader? _shader;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _maybeLoadShader();
  }

  /// Resolved Tier 3 intent: explicit override, else on for everything but
  /// `sheet` (largest surface; refraction there is cost without payoff).
  bool get _wantsRefraction =>
      widget.refractive ?? widget.variant != MaliGlassVariant.sheet;

  @override
  void didUpdateWidget(MaliGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refractive != oldWidget.refractive ||
        widget.variant != oldWidget.variant) {
      _maybeLoadShader();
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  void _maybeLoadShader() {
    if (!_wantsRefraction) return;
    // Runtime capability, not platform name: shader image filters exist only
    // on Impeller. Off Impeller this never loads and Tier 2 renders instead.
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    if (_displacementMap == null) {
      // The reference's `generateShaderDisplacementMap` — computed once and
      // cached process-wide.
      _displacementMapFuture ??= ShaderDisplacementGenerator(
        width: _mapSize,
        height: _mapSize,
        fragment: fragmentShaders['liquidGlass']!,
      ).updateShader();
      _displacementMapFuture!.then((image) {
        _displacementMap = image;
        if (mounted && _wantsRefraction) setState(() {});
      }, onError: (Object error, StackTrace stackTrace) {
        // Map generation failure → stay on Tier 2 silently.
      });
    }
    final cached = _refractionProgram;
    if (cached != null) {
      _shader ??= cached.fragmentShader();
      return;
    }
    _refractionFuture ??=
        ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
    _refractionFuture!.then((program) {
      _refractionProgram = program;
      if (!mounted || !_wantsRefraction || _shader != null) return;
      setState(() => _shader = program.fragmentShader());
    }, onError: (Object error, StackTrace stackTrace) {
      // Missing/incompatible shader asset → stay on Tier 2 silently.
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final media = MediaQuery.maybeOf(context);
    final reduceMotion = media?.disableAnimations ?? false;
    final spec = _MaliGlassSpec.resolve(widget.variant, isDark);
    // headerAction sits on the opaque blue header: contrast is guaranteed by
    // the header itself, and the opaque fallback would hide its white icons.
    final onAccent = widget.variant == MaliGlassVariant.headerAction;
    final highContrast = !onAccent && (media?.highContrast ?? false);
    final sheen = spec.sheen ?? t.glassSheen;
    final br = widget.radius != null
        ? BorderRadius.circular(widget.radius!)
        : spec.borderRadius;
    final isSheet = widget.variant == MaliGlassVariant.sheet;
    final interactive = widget.onTap != null && widget.enabled;

    Widget content = Padding(
      padding: widget.padding ?? spec.padding,
      child: widget.child,
    );

    if (interactive) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: br,
          highlightColor: Colors.transparent,
          onHighlightChanged: (v) => setState(() => _pressed = v),
          child: content,
        ),
      );
    }

    final Widget layered = interactive
        ? Stack(
            children: [
              content,
              Positioned.fill(
                child: IgnorePointer(
                  child: _pressGlow(br, sheen, reduceMotion),
                ),
              ),
            ],
          )
        : content;

    // Generic MaliGlass NEVER self-selects the native platform-view tier:
    // native UIGlassEffect ownership lives with explicit native hosts only
    // (today: the pre-existing iOS 26 bottom-navigation host outside this
    // widget). Generic surfaces resolve: opaque → advanced → frost.
    Widget surface;
    if (resolveGlassTier(
          advancedRequested: widget.advancedRefraction && !isSheet,
          shaderSupported: advancedShaderSupported,
          platformAllowed: advancedTierAllowedOnPlatform,
          highContrast: highContrast,
          nativeGlassActive: false,
        ) ==
        GlassTier.advanced) {
      // ADVANCED TIER: package-backed refraction (pilot surfaces only).
      // The package renders body + lighting; Qirsh keeps the token rim,
      // press affordances, semantics, and every fallback decision.
      surface = buildAdvancedGlassSurface(
        context: context,
        cornerRadius: _maxCorner(br),
        isDark: isDark,
        child: layered,
      );
      surface = CustomPaint(
        key: const ValueKey('MaliGlassAdvancedSurface'),
        foregroundPainter: _GlassRimPainter(
          borderRadius: br,
          stroke: spec.stroke ?? t.glassStroke,
          sheen: sheen,
        ),
        child: surface,
      );
    } else {
      // Fill + press highlight. The highlight is our own (token sheen)
      // overlay, kept as an instant static state under reduce-motion.
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: br,
          gradient: highContrast
              ? null
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // Sheet: a thin translucent band at the top edge, then a
                  // near-opaque body — forms never sit on see-through glass.
                  colors: [
                    spec.fillTop ?? t.glassFillTop,
                    isSheet
                        ? t.glassSheetFill
                        : (spec.fillBottom ?? t.glassFillBottom),
                  ],
                  stops: isSheet ? const [0.0, 0.06] : null,
                ),
          color: highContrast ? (isDark ? c.surfaceElevated : c.surface) : null,
        ),
        child: layered,
      );

      final canRefract = _refractionReady;
      surface = CustomPaint(
        foregroundPainter: _GlassRimPainter(
          borderRadius: br,
          stroke: highContrast ? c.border : (spec.stroke ?? t.glassStroke),
          sheen: highContrast ? const Color(0x00000000) : sheen,
          // Refractive surfaces wear the reference's double gradient border
          // instead of the token rim.
          reactBorder: canRefract && !highContrast,
        ),
        child: surface,
      );

      // headerAction skips the backdrop entirely (blurring a flat gradient is
      // invisible) — unless the refraction lens is live, which does show.
      if (!highContrast && (spec.blurSigma > 0 || canRefract)) {
        surface = BackdropFilter(filter: _buildFilter(br), child: surface);
      }
    }

    surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow:
            !highContrast && _refractionReady ? _refractiveShadow : spec.shadow,
      ),
      child: ClipRRect(borderRadius: br, child: surface),
    );

    if (interactive) {
      surface = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        child: surface,
      );
      // Under reduce-motion the surface stays structurally static: no
      // animation widgets at all (zero-duration implicit animations can
      // re-enter the build loop during pointer dispatch).
      if (!reduceMotion) {
        surface = AnimatedScale(
          // Reference active scale: 0.96.
          scale: _pressed ? 0.96 : 1.0,
          duration: AppMotion.buttonPress,
          curve: AppMotion.buttonCurve,
          child: surface,
        );
      }
      // InkWell contributes the tap action + focus; the button role must be
      // declared explicitly and merged so screen readers announce one
      // "<label>, button" node.
      surface = MergeSemantics(
        child: Semantics(button: true, child: surface),
      );
    }

    return surface;
  }

  static double _maxCorner(BorderRadius br) => [
        br.topLeft.x,
        br.topRight.x,
        br.bottomLeft.x,
        br.bottomRight.x,
      ].reduce(math.max);

  /// Press glow overlay. Under reduce-motion it is a plain [Opacity] — the
  /// state change stays visible with no animation machinery involved.
  Widget _pressGlow(BorderRadius br, Color sheen, bool reduceMotion) {
    final glow = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        gradient: RadialGradient(
          center: Alignment.topCenter,
          radius: 1.3,
          colors: [
            sheen.withValues(alpha: sheen.a * 0.30),
            sheen.withValues(alpha: 0),
          ],
        ),
      ),
    );
    if (reduceMotion) {
      return Opacity(opacity: _pressed ? 1.0 : 0.0, child: glow);
    }
    return AnimatedOpacity(
      opacity: _pressed ? 1.0 : 0.0,
      duration: AppMotion.fast,
      curve: AppMotion.buttonCurve,
      child: glow,
    );
  }

  /// True when every piece of the reference pipeline is live: intent,
  /// runtime support, the compiled program, and the generated map.
  bool get _refractionReady =>
      _wantsRefraction &&
      _shader != null &&
      _displacementMap != null &&
      ui.ImageFilter.isShaderFilterSupported;

  ui.ImageFilter _buildFilter(BorderRadius br) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final spec = _MaliGlassSpec.resolve(widget.variant, isDark);
    final refract = _refractionReady;
    // headerAction keeps zero blur even when refracting (flat backdrop).
    final sigma = refract
        ? (spec.blurSigma == 0 ? 0.0 : _refractiveBlurSigma)
        : spec.blurSigma;
    ui.ImageFilter filter = ui.ImageFilter.compose(
      outer: ui.ColorFilter.matrix(
        _saturationMatrix(
          refract ? _refractiveSaturation : (isDark ? 1.30 : 1.15),
        ),
      ),
      inner: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
    if (refract) {
      final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
      final shader = _shader!;
      shader
        ..setFloat(2, _displacementScale * dpr)
        ..setFloat(3, _aberrationIntensity)
        ..setImageSampler(1, _displacementMap!);
      filter = ui.ImageFilter.compose(
        outer: ui.ImageFilter.shader(shader),
        inner: filter,
      );
    }
    return filter;
  }

  /// Standard luminance-preserving saturation matrix (s = 1 is identity).
  static List<double> _saturationMatrix(double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    return <double>[
      lr + (1 - lr) * s, lg * (1 - s), lb * (1 - s), 0, 0, //
      lr * (1 - s), lg + (1 - lg) * s, lb * (1 - s), 0, 0, //
      lr * (1 - s), lg * (1 - s), lb + (1 - lb) * s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }
}

class _MaliGlassSpec {
  const _MaliGlassSpec({
    required this.borderRadius,
    required this.padding,
    required this.blurSigma,
    required this.shadow,
    this.fillTop,
    this.fillBottom,
    this.stroke,
    this.sheen,
  });

  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final double blurSigma;
  final List<BoxShadow> shadow;

  /// Token overrides for on-accent contexts; null = use [MaliTokens].
  final Color? fillTop;
  final Color? fillBottom;
  final Color? stroke;
  final Color? sheen;

  static _MaliGlassSpec resolve(MaliGlassVariant variant, bool isDark) {
    switch (variant) {
      case MaliGlassVariant.pill:
        return const _MaliGlassSpec(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          blurSigma: 20,
          shadow: [],
        );
      case MaliGlassVariant.card:
        return const _MaliGlassSpec(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.xxl)),
          padding: EdgeInsets.all(AppSpacing.cardPadding),
          blurSigma: 20,
          shadow: [
            BoxShadow(
              color: Color(0x0F101828),
              blurRadius: 14,
              offset: Offset(0, 2),
            ),
          ],
        );
      case MaliGlassVariant.navigation:
        // Matches the nav bar fallback exactly (radius 26, blur 24, and the
        // mode-dependent drop shadow it has always used).
        return _MaliGlassSpec(
          borderRadius: const BorderRadius.all(Radius.circular(26)),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          blurSigma: 24,
          shadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.13),
              blurRadius: 30,
              offset: const Offset(0, 14),
            ),
          ],
        );
      case MaliGlassVariant.sheet:
        // Bottom-sheet material: top-only radius (AppRadius.sheet), near-
        // opaque body (see the fill gradient), and the upward sheet shadow.
        return const _MaliGlassSpec(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
          padding: EdgeInsets.zero,
          blurSigma: 20,
          shadow: [
            BoxShadow(
              color: Color(0x29101828),
              blurRadius: 34,
              offset: Offset(0, -10),
            ),
          ],
        );
      case MaliGlassVariant.headerAction:
        // On the opaque blue header gradient: no blur (nothing to blur),
        // mode-invariant white recipe, circular by default.
        return const _MaliGlassSpec(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
          padding: EdgeInsets.zero,
          blurSigma: 0,
          shadow: [],
          fillTop: Color(0x38FFFFFF), // white @ ~22%
          fillBottom: Color(0x1FFFFFFF), // white @ ~12%
          stroke: Color(0x47FFFFFF), // white @ ~28% (matches old border)
          sheen: Color(0x99FFFFFF), // white @ ~60%
        );
    }
  }
}

/// 1px rim + top specular edge. Vertical gradients only, so the rim reads
/// identically under RTL and LTR.
class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({
    required this.borderRadius,
    required this.stroke,
    required this.sheen,
    this.reactBorder = false,
  });

  final BorderRadius borderRadius;
  final Color stroke;
  final Color sheen;

  /// Paints rdev/liquid-glass-react's two border layers instead of the token
  /// rim (their "Border layer 1/2": 1.5px ring, 135° white gradient — layer 1
  /// screen-blended at opacity 0.2 with stops 0/.12/.4/0, layer 2
  /// overlay-blended with stops 0/.32/.6/0; mouseOffset terms at rest = 0).
  final bool reactBorder;

  static const _reactStops = [0.0, 0.33, 0.66, 1.0];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (reactBorder) {
      final ring = borderRadius.toRRect(rect).deflate(0.75);
      Paint layer(List<double> alphas, BlendMode mode) => Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..blendMode = mode
        ..shader = ui.Gradient.linear(
          rect.topLeft, // CSS 135deg: top-left → bottom-right.
          rect.bottomRight,
          [for (final a in alphas) Colors.white.withValues(alpha: a)],
          _reactStops,
        );
      // Layer 1 alphas pre-multiplied by the span's opacity: 0.2.
      canvas.drawRRect(
          ring, layer(const [0, 0.024, 0.08, 0], BlendMode.screen));
      canvas.drawRRect(ring, layer(const [0, 0.32, 0.6, 0], BlendMode.overlay));
      return;
    }
    final rrect = borderRadius.toRRect(rect).deflate(0.5);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = stroke,
    );
    if (sheen.a > 0) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..blendMode = BlendMode.screen
          ..shader = ui.Gradient.linear(
            rect.topCenter,
            rect.bottomCenter,
            [sheen, sheen.withValues(alpha: 0)],
            [0.0, 0.45],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.stroke != stroke ||
      oldDelegate.sheen != sheen ||
      oldDelegate.reactBorder != reactBorder;
}
