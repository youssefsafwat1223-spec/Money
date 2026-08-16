#version 460 core

// Stage-for-stage port of the rdev/liquid-glass-react SVG filter chain
// (src/index.tsx `GlassFilter`, "shader" mode), applied to the backdrop via
// ui.ImageFilter.shader (Impeller-only; callers gate on
// ui.ImageFilter.isShaderFilterSupported).
//
// u_map is the displacement map produced by ShaderDisplacementGenerator
// (lib/core/theme/widgets/liquid_glass/shader_utils.dart — a verbatim Dart
// port of the reference's shader-utils.ts): dx in R, dy in G and B around a
// 0.5 neutral. Like the reference's `feImage x=0 y=0 width=100% height=100%`,
// the map is stretched across the element.
//
// The reference's chain:
//   feDisplacementMap(scale = S)                xChannel=R yChannel=B → RED
//   feDisplacementMap(scale = S*(1 - ab*.05))                        → GREEN
//   feDisplacementMap(scale = S*(1 - ab*.10))                        → BLUE
//   channel-isolate each (feColorMatrix), feBlend screen ×2
// Screen-blending channel-disjoint layers is an exact channel gather
// (screen(a, 0) = a), which is what main() computes. The declared edge mask's
// discrete transfer evaluates to 1 everywhere (the map's neutral center is
// what keeps the middle undistorted) and the ≤0.5px feGaussianBlur soften is
// sub-pixel — both intentionally omitted.
//
// ImageFilter.shader contract: first uniform must be a vec2 (engine-set input
// size); first sampler is the filter input. Dart float indices start at 2.

precision mediump float;

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;        // engine-set: input texture size (physical px)
uniform float u_scale;      // displacementScale, physical px (reference: 70)
uniform float u_aberration; // aberrationIntensity (reference: 2)

uniform sampler2D u_texture; // engine-set: backdrop (already blur+saturate)
uniform sampler2D u_map;     // ShaderDisplacementGenerator output

out vec4 frag_color;

vec4 sample_backdrop(vec2 px) {
  vec2 uv = clamp(px / u_size, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(u_texture, uv);
}

void main() {
  vec2 coord = FlutterFragCoord().xy;
  vec2 uv = coord / u_size;

  // feDisplacementMap: P' = P + scale * (XC(P) - 0.5, YC(P) - 0.5), with
  // positive scale in the reference's "shader" mode.
  vec4 map_v = texture(u_map, uv);
  vec2 d = vec2(map_v.r - 0.5, map_v.b - 0.5);

  float s_r = u_scale;
  float s_g = u_scale * (1.0 - u_aberration * 0.05);
  float s_b = u_scale * (1.0 - u_aberration * 0.1);

  float r = sample_backdrop(coord + d * s_r).r;
  vec4 g = sample_backdrop(coord + d * s_g);
  float b = sample_backdrop(coord + d * s_b).b;

  frag_color = vec4(r, g.g, b, g.a);
}
