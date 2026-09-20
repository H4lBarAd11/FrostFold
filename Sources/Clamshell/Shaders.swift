import simd

/// Metal source compiled at runtime via `MTLDevice.makeLibrary(source:options:)`,
/// so the project builds with Command Line Tools alone — no `metal` compiler,
/// no Xcode, no checked-in `.metallib`.
enum Shaders {

/// Mirrors `PaneUniforms` in the Metal source below. Field order and padding
/// must stay in lockstep.
struct PaneUniforms {
    var foldRadians: Float = 0
    var cameraDistance: Float = 8
    var scatter: Float = 0
    var opacity: Float = 0
    var edgeSoftness: Float = 0
    var cornerRadius: Float = 0
    var grainAmount: Float = 1
    var aspect: Float = 1.6
    var grainScale: SIMD2<Float> = .init(120, 75)
    var viewportSize: SIMD2<Float> = .init(1, 1)
    var mode: Int32 = 0          // 0 = lift a copy, 1 = see through
    var _pad: Float = 0
}

struct BlurUniforms {
    var direction: SIMD2<Float> = .init(1, 0)   // texel step
}

static let source = """
#include <metal_stdlib>
using namespace metal;

struct PaneUniforms {
    float  foldRadians;
    float  cameraDistance;
    float  scatter;
    float  opacity;
    float  edgeSoftness;
    float  cornerRadius;
    float  grainAmount;
    float  aspect;
    float2 grainScale;
    float2 viewportSize;
    int    mode;          // 0 = lift a copy of the display, 1 = see through
    float  _pad;
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

// Four-tap box reduction; run repeatedly to walk the capture down to a cheap
// resolution before blurring.
fragment half4 downsample_fragment(BlitOut in [[stage_in]],
                                   texture2d<half> src [[texture(0)]]) {
    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    half4 c = src.sample(linearSampler, in.uv + texel * float2(-0.5, -0.5));
    c += src.sample(linearSampler, in.uv + texel * float2( 0.5, -0.5));
    c += src.sample(linearSampler, in.uv + texel * float2(-0.5,  0.5));
    c += src.sample(linearSampler, in.uv + texel * float2( 0.5,  0.5));
    return c * 0.25h;
}

fragment half4 copy_fragment(BlitOut in [[stage_in]],
                             texture2d<half> src [[texture(0)]]) {
    return src.sample(linearSampler, in.uv);
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
    float2 uv;       // into the captured display texture
    float2 pane;     // pane-local coordinates, [-1,1] on both axes
    float  lift;     // 0 at the hinge, 1 at the free edge
};

vertex PaneOut pane_vertex(uint vid [[vertex_id]],
                           constant PaneUniforms& u [[buffer(0)]]) {
    // Triangle strip over the unit quad.
    const float2 corners[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 p = corners[vid];

    // Hinge runs along the bottom edge (y = -1); the pane rotates about it,
    // +z toward the viewer.
    float h = p.y + 1.0;
    float c = cos(u.foldRadians);
    float s = sin(u.foldRadians);
    float y = h * c - 1.0;
    float z = h * s;

    // Leave the divide to the rasteriser so the texture stays perspective
    // correct across the whole pane.
    float w = (u.cameraDistance - z) / u.cameraDistance;

    PaneOut out;
    out.position = float4(p.x, y, 0.0, w);
    out.uv       = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    out.pane     = p;
    out.lift     = h * 0.5;
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

fragment half4 pane_fragment(PaneOut in [[stage_in]],
                             texture2d<half> sharpTex [[texture(0)]],
                             texture2d<half> blurTex  [[texture(1)]],
                             constant PaneUniforms& u [[buffer(0)]]) {

    // --- silhouette -------------------------------------------------------
    float2 P = float2(in.pane.x * u.aspect, in.pane.y);
    float2 halfExtent = float2(u.aspect, 1.0);
    float radius = u.cornerRadius * 0.95;
    float d = sdRoundBox(P, halfExtent, radius);

    float feather = 0.003 + u.edgeSoftness * 0.30;
    float mask = 1.0 - smoothstep(-feather, 0.0, d);
    if (mask <= 0.001h) { discard_fragment(); }

    // --- material ---------------------------------------------------------
    // Grain is keyed to pane-local coordinates, so it lives in the glass and
    // travels with it rather than sitting on the display behind.
    float2 g = in.pane * u.grainScale;
    float n1 = valueNoise(g) * 2.0 - 1.0;
    float n2 = valueNoise(g + 31.7) * 2.0 - 1.0;

    // Scattering grows with distance from the hinge: the further the glass
    // stands off the display, the more it diffuses what is behind it.
    float frost = clamp(u.scatter * (0.55 + 0.45 * in.lift), 0.0, 1.0);

    // Etched glass displaces as well as diffuses, but the displacement belongs
    // on the diffuse lobe only. Jittering the sharp sample turns the pane into
    // static rather than glass.
    float2 jitter = float2(n1, n2) * 0.0022 * frost;

    // Mode 0 carries a copy of the display on the pane, so the image lifts and
    // leans with the glass. Mode 1 keeps the pane empty and shows whatever lies
    // behind it on the real display, refracted by the tilt.
    float2 base;
    if (u.mode == 0) {
        base = in.uv;
    } else {
        base = in.position.xy / u.viewportSize;
        // A tilted pane pushes what is behind it away from the hinge.
        base.y -= sin(u.foldRadians) * in.lift * 0.035;
    }

    half4 sharp = sharpTex.sample(linearSampler, clamp(base, 0.0, 1.0));
    half4 diffuse = blurTex.sample(linearSampler, clamp(base + jitter, 0.0, 1.0));
    half3 col = mix(sharp.rgb, diffuse.rgb, half(frost));

    // Milkiness, not reflection: etched glass scatters light, it does not
    // mirror it, so there is no specular term anywhere in here.
    half lum = dot(col, half3(0.2126h, 0.7152h, 0.0722h));
    col = mix(col, half3(lum), half(0.16 * frost));

    // Grain in the material itself — a gentle modulation, not a dusting of noise.
    col *= half(1.0 + n1 * 0.045 * u.grainAmount * frost);

    // Transmission falls off as the pane leans away from the viewer.
    float grazing = 1.0 - 0.18 * in.lift * sin(u.foldRadians);
    col *= half(grazing);

    float alpha = mask * u.opacity;
    return half4(clamp(col, 0.0h, 1.0h), half(alpha));
}
"""
}
