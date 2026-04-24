//
//  NormalBlendFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// Manual bilinear read — lets the overlay be any resolution without
// requiring the caller to bind a sampler (ComputeDispatcher's binding
// convention uses access::read for additional inputs). On dimension-
// matched overlays the bilinear call collapses to a single texel read
// because frac(coord) == 0.
inline half4 dcr_blendBilinear(texture2d<half, access::read> tex, float2 coord) {
    int2 p = int2(floor(coord));
    float2 f = fract(coord);
    int maxX = int(tex.get_width()) - 1;
    int maxY = int(tex.get_height()) - 1;
    half4 c00 = tex.read(uint2(clamp(p.x,     0, maxX), clamp(p.y,     0, maxY)));
    half4 c10 = tex.read(uint2(clamp(p.x + 1, 0, maxX), clamp(p.y,     0, maxY)));
    half4 c01 = tex.read(uint2(clamp(p.x,     0, maxX), clamp(p.y + 1, 0, maxY)));
    half4 c11 = tex.read(uint2(clamp(p.x + 1, 0, maxX), clamp(p.y + 1, 0, maxY)));
    return mix(mix(c00, c10, half(f.x)), mix(c01, c11, half(f.x)), half(f.y));
}

struct NormalBlendUniforms {
    float intensity;   // 0 ... 1
};

kernel void DCRLegacyBlendNormalFilter(
    texture2d<half, access::write> output  [[texture(0)]],
    texture2d<half, access::read>  input   [[texture(1)]],
    texture2d<half, access::read>  overlay [[texture(2)]],
    constant NormalBlendUniforms& u        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    const half4 inColor = input.read(gid);

    // Map the output pixel-center into the overlay texture's coord
    // space. Bilinear handles dimension mismatch; when dimensions
    // match exactly, coord lands on a texel center and frac == 0.
    const float2 coord = (float2(gid) + 0.5f)
        * float2(float(overlay.get_width()) / float(outW),
                 float(overlay.get_height()) / float(outH))
        - 0.5f;
    const half4 over = dcr_blendBilinear(overlay, coord);

    // Porter-Duff "source over" compositing of overlay on input.
    half4 composited;
    composited.rgb = over.rgb + inColor.rgb * inColor.a * (1.0h - over.a);
    composited.a   = over.a   + inColor.a               * (1.0h - over.a);

    const half t = half(clamp(u.intensity, 0.0f, 1.0f));
    const half4 result = mix(inColor, composited, t);
    output.write(result, gid);
}
