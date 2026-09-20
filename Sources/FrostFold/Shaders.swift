import simd

/// Metal source compiled at runtime via `MTLDevice.makeLibrary(source:options:)`,
/// so the project builds with Command Line Tools alone — no `metal` compiler,
/// no Xcode, no checked-in `.metallib`.
enum Shaders {

/// Mirrors `PaneUniforms` in the Metal source below. Field order and padding
/// must stay in lockstep (48 bytes, 8-byte aligned).
struct PaneUniforms {
    /// Tilt of the pane away from the display, in radians. Drives the gap.
    var foldRadians: Float = 0
    /// Frost at the top edge, 0...1+. The gradient scales down to 0 at the hinge.
    var frostAmount: Float = 0
    /// Shapes how the gap opens with height. 1 is linear.
    var gapCurve: Float = 1
    /// Global fade, used to bring the pane in and out.
    var opacity: Float = 1
    var edgeSoftness: Float = 0
    /// Corner rounding of the free (top) corners, as a fraction of pane height.
    var cornerRadius: Float = 0
    var grainAmount: Float = 1
    var aspect: Float = 1.6
    var grainScale: SIMD2<Float> = .init(120, 75)
    var viewportSize: SIMD2<Float> = .init(1, 1)
}

struct BlurUniforms {
    var direction: SIMD2<Float> = .init(1, 0)   // texel step
}

static let source = """
#include <metal_stdlib>
using namespace metal;

struct PaneUniforms {
    float  foldRadians;
    float  frostAmount;
    float  gapCurve;
    float  opacity;
    float  edgeSoftness;
    float  cornerRadius;
    float  grainAmount;
    float  aspect;
    float2 grainScale;
    float2 viewportSize;
};

struct BlurUniforms { float2 direction; };

constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

// ---------------------------------------------------------------- full-screen

struct BlitOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitOut blit_vertex(uint vid [[vertex_id]]) {
    float2 t = float2((vid << 1) & 2, vid & 2);
    BlitOut out;
    out.position = float4(t * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(t.x, 1.0 - t.y);
    return out;
}

fragment half4 copy_fragment(BlitOut in [[stage_in]],
                             texture2d<half> src [[texture(0)]]) {
    return src.sample(linearSampler, in.uv);
}

// Four-tap box reduction; run repeatedly to walk the capture down the pyramid.
fragment half4 downsample_fragment(BlitOut in [[stage_in]],
                                   texture2d<half> src [[texture(0)]]) {
    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    half4 c = src.sample(linearSampler, in.uv + texel * float2(-0.5, -0.5));
    c += src.sample(linearSampler, in.uv + texel * float2( 0.5, -0.5));
    c += src.sample(linearSampler, in.uv + texel * float2(-0.5,  0.5));
    c += src.sample(linearSampler, in.uv + texel * float2( 0.5,  0.5));
    return c * 0.25h;
}

// Separable Gaussian, nine taps via five linearly-interpolated fetches.
fragment half4 blur_fragment(BlitOut in [[stage_in]],
                             texture2d<half> src [[texture(0)]],
                             constant BlurUniforms& u [[buffer(0)]]) {
    const float offsets[3] = { 0.0, 1.3846153846, 3.2307692308 };
    const half  weights[3] = { 0.2270270270h, 0.3162162162h, 0.0702702703h };

    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    float2 step = u.direction * texel;

    half4 c = src.sample(linearSampler, in.uv) * weights[0];
    for (int i = 1; i < 3; ++i) {
        c += src.sample(linearSampler, in.uv + step * offsets[i]) * weights[i];
        c += src.sample(linearSampler, in.uv - step * offsets[i]) * weights[i];
    }
    return c;
}

// --------------------------------------------------------------- glass pane

struct PaneOut {
    float4 position [[position]];
    float2 uv;     // screen-space, and therefore also display-texture space
    float2 pane;   // pane-local, [-1,1] on both axes
};

// The pane covers the display. It is hinged along the bottom edge and tilts
// away from the screen, but it does not carry a copy of the display with it —
// what you see through it stays exactly where it is. Only the gap changes.
vertex PaneOut pane_vertex(uint vid [[vertex_id]]) {
    const float2 corners[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 p = corners[vid];

    PaneOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv       = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    out.pane     = p;
    return out;
}

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Smoothly interpolated value noise. Per-cell hashing on its own reads as
// salt-and-pepper static; etched glass has structure, not speckle.
static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Signed distance to a rounded box, negative inside.
static inline float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// A blur pyramid sampled continuously. Crossfading a single blurred copy
// against the sharp frame reads as haze laid over a still-sharp picture;
// walking the pyramid genuinely defocuses, which is what a diffuser does.
static inline half4 pyramid(float t, float2 uv,
                            texture2d<half> l0, texture2d<half> l1,
                            texture2d<half> l2, texture2d<half> l3) {
    if (t <= 0.0) return l0.sample(linearSampler, uv);
    if (t < 1.0)  return mix(l0.sample(linearSampler, uv),
                             l1.sample(linearSampler, uv), half(t));
    if (t < 2.0)  return mix(l1.sample(linearSampler, uv),
                             l2.sample(linearSampler, uv), half(t - 1.0));
    return mix(l2.sample(linearSampler, uv),
               l3.sample(linearSampler, uv), half(min(t - 2.0, 1.0)));
}

fragment half4 pane_fragment(PaneOut in [[stage_in]],
                             texture2d<half> l0 [[texture(0)]],
                             texture2d<half> l1 [[texture(1)]],
                             texture2d<half> l2 [[texture(2)]],
                             texture2d<half> l3 [[texture(3)]],
                             constant PaneUniforms& u [[buffer(0)]]) {

    // --- the gap ----------------------------------------------------------
    // Nothing at the hinge, growing toward the top. This is the whole effect:
    // clear where the glass touches the display, frosted where it lifts away.
    float height = 1.0 - in.uv.y;                     // 0 at the hinge, 1 at the top
    float gap = pow(height, u.gapCurve) * sin(u.foldRadians);
    float frost = clamp(gap * u.frostAmount, 0.0, 1.0);

    if (frost <= 0.0005) { discard_fragment(); }

    // --- silhouette -------------------------------------------------------
    // Only the free corners are rounded; the hinged edge runs straight along
    // the bottom of the display.
    float2 P = float2(in.pane.x * u.aspect, in.pane.y);
    float radius = u.cornerRadius * 0.95;
    float d = (in.pane.y > 0.0)
        ? sdRoundBox(P, float2(u.aspect, 1.0), radius)
        : max(abs(P.x) - u.aspect, -P.y - 1.0);

    float feather = 0.003 + u.edgeSoftness * 0.30;
    float mask = 1.0 - smoothstep(-feather, 0.0, d);
    if (mask <= 0.001) { discard_fragment(); }

    // --- material ---------------------------------------------------------
    float2 g = in.pane * u.grainScale;
    float n1 = valueNoise(g) * 2.0 - 1.0;
    float n2 = valueNoise(g + 31.7) * 2.0 - 1.0;

    // Etched glass displaces as well as diffuses, and it displaces more where
    // the gap is wider.
    float2 jitter = float2(n1, n2) * 0.0015 * frost;
    float2 uv = clamp(in.uv + jitter, 0.0, 1.0);

    // Walk the pyramid by the local frost. Three intervals across four levels.
    half3 col = pyramid(frost * 3.0, uv, l0, l1, l2, l3).rgb;

    // Milkiness, not reflection: etched glass scatters light, it does not
    // mirror it, so there is no specular term anywhere in here.
    half lum = dot(col, half3(0.2126h, 0.7152h, 0.0722h));
    col = mix(col, half3(lum), half(0.17 * frost));
    col += half3(half(0.045 * frost));

    // Grain in the material itself — a gentle modulation, not a dusting of noise.
    col *= half(1.0 + n1 * 0.03 * u.grainAmount * frost);

    // Opaque wherever there is any frost at all, so the sharp frame underneath
    // never shows through and double-exposes the blurred one. The thin ramp
    // keeps the hinge edge from cutting a hard line across the display.
    float alpha = mask * u.opacity * smoothstep(0.0, 0.02, frost);
    return half4(clamp(col, 0.0h, 1.0h), half(alpha));
}
"""
}
