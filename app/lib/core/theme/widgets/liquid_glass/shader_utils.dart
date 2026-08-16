// Verbatim Dart port of rdev/liquid-glass-react `src/shader-utils.ts`
// (itself adapted from https://github.com/shuding/liquid-glass).
//
// Same names, same math, same output bytes: the displacement map encodes
// dx in RED and dy in GREEN and BLUE around a 0.5 neutral, normalized by the
// map's maximum displacement and smoothed within 2px of the canvas edge —
// exactly what the reference feeds SVG `feDisplacementMap`
// (xChannelSelector="R" yChannelSelector="B"). The only difference is the
// output container: a `ui.Image` for `FragmentShader.setImageSampler`
// instead of an HTMLCanvas data URL.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

class Vec2 {
  const Vec2(this.x, this.y);
  final double x;
  final double y;
}

typedef ShaderFragment = Vec2 Function(Vec2 uv, [Vec2? mouse]);

double smoothStep(double a, double b, double t) {
  t = ((t - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double length(double x, double y) => math.sqrt(x * x + y * y);

double roundedRectSDF(
    double x, double y, double width, double height, double radius) {
  final qx = x.abs() - width + radius;
  final qy = y.abs() - height + radius;
  return math.min(math.max(qx, qy), 0.0) +
      length(math.max(qx, 0.0), math.max(qy, 0.0)) -
      radius;
}

Vec2 texture(double x, double y) => Vec2(x, y);

/// Shader fragment functions for different effects — reference
/// `fragmentShaders.liquidGlass` verbatim (its SDF constants are in
/// normalized UV space, so the lens shape is size-independent).
final Map<String, ShaderFragment> fragmentShaders = {
  'liquidGlass': (Vec2 uv, [Vec2? mouse]) {
    final ix = uv.x - 0.5;
    final iy = uv.y - 0.5;
    final distanceToEdge = roundedRectSDF(ix, iy, 0.3, 0.2, 0.6);
    final displacement = smoothStep(0.8, 0, distanceToEdge - 0.15);
    final scaled = smoothStep(0, 1, displacement);
    return texture(ix * scaled + 0.5, iy * scaled + 0.5);
  },
};

class ShaderDisplacementGenerator {
  ShaderDisplacementGenerator({
    required this.width,
    required this.height,
    required this.fragment,
  });

  final int width;
  final int height;
  final ShaderFragment fragment;
  final int canvasDPI = 1;

  /// The reference's `updateShader()`: computes raw displacements, then the
  /// improved normalization and 2px edge smoothing, and packs R=dx, G=dy,
  /// B=dy (SVG filter compatibility), A=255.
  Future<ui.Image> updateShader([Vec2? mousePosition]) {
    final w = width * canvasDPI;
    final h = height * canvasDPI;

    double maxScale = 0;
    final rawValues = <double>[];

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final uv = Vec2(x / w, y / h);
        final pos = fragment(uv, mousePosition);
        final dx = pos.x * w - x;
        final dy = pos.y * h - y;
        maxScale = math.max(maxScale, math.max(dx.abs(), dy.abs()));
        rawValues
          ..add(dx)
          ..add(dy);
      }
    }

    // Improved normalization to prevent artifacts while maintaining intensity.
    maxScale = maxScale > 0 ? math.max(maxScale, 1) : 1;

    final data = Uint8List(w * h * 4);
    var rawIndex = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = rawValues[rawIndex++];
        final dy = rawValues[rawIndex++];

        // Smooth the displacement values at edges to prevent hard transitions.
        final edgeDistance =
            [x, y, w - x - 1, h - y - 1].reduce(math.min).toDouble();
        final edgeFactor = math.min(1.0, edgeDistance / 2);

        final r = (dx * edgeFactor) / maxScale + 0.5;
        final g = (dy * edgeFactor) / maxScale + 0.5;

        final pixelIndex = (y * w + x) * 4;
        data[pixelIndex] = (r * 255).clamp(0, 255).round();
        data[pixelIndex + 1] = (g * 255).clamp(0, 255).round();
        data[pixelIndex + 2] = (g * 255).clamp(0, 255).round();
        data[pixelIndex + 3] = 255;
      }
    }

    return ui.ImmutableBuffer.fromUint8List(data).then(
      (buffer) => ui.ImageDescriptor.raw(
        buffer,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      ).instantiateCodec(),
    ).then((codec) => codec.getNextFrame()).then((frame) => frame.image);
  }

  int getScale() => canvasDPI;
}
