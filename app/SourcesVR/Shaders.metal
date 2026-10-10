// 等幅左右眼的 DIBR：后向 remap（补洞用的底）+ 前向 splat（z 缓冲取最近）+ 合洞。
// 照的是 PC 那套 post_vr.py 的 m6 臂：dd=(dn-zp)*budget，左眼 dest=x+dd，右眼 dest=x-dd，
// 同格相撞取 dd 最大（最近）的那个，剩下没被写到的格子用后向 remap 那份填。
//
// 通道序在这里一律不解释：帧从 kCVPixelFormatType_32BGRA 的像素缓冲进来，最后写回同样是
// BGRA 的像素缓冲，中间只做整 texel 的搬运和线性插值，读写两次换算是同一次对调 ⇒ 字节原样回还。
// 这条假设由 app 里的「色彩往返自检」在上机时量，不是靠文档信。
#include <metal_stdlib>
using namespace metal;

struct VRP {
    uint  W;        // 每眼宽
    uint  H;        // 每眼高
    uint  MW;       // 送检图宽
    uint  MH;       // 送检图高
    float scale;    // 眼 → 送检 的等比缩放（rot=1 时是「转 90° 后的那张」→ 送检）
    float ox;       // 送检图里图像区的左边界（黑边宽度）
    float oy;       // 同上，上边界
    float zp;       // 零视差面：归一化深度等于它的正好落在屏幕上
    float budget;   // 最大视差（像素，按每眼宽算）
    uint  SW;       // 成片宽 = 2W
    uint  rot;      // 0=摆正送检；1=顺时针转 90° 送检（只有 kScale 读它）
};

constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);

// dd 可正可负，要按大小比先后就得换成一个「越大越近」的无符号序（IEEE 浮点的经典单调映射）。
// 0 号值留给「这一格没人写过」：encOrder 出 0 只可能是 -NaN，而 dd 已被 clamp 掉 NaN/inf。
static inline uint encOrder(float v) {
    uint b = as_type<uint>(v);
    return (b & 0x80000000u) ? ~b : (b | 0x80000000u);
}

static inline float ddOf(device const float* dn, uint idx, constant VRP& P) {
    return clamp((dn[idx] - P.zp) * P.budget, -4096.0, 4096.0);
}

// 0) 眼尺寸的帧 → 送检尺寸：等比塞进去，四周留黑边。留边是为了不拉伸——拉伸会把深度也拉歪。
// rot=1 时先顺时针转 90° 再塞：竖屏 540x960 摆正只能占 220x392，转过去能占满 518x291（有效像素 +75%），
// 而模型那 518x392 的固定输入和单价一分不变。
// ⚠️ 下面这条 画布 → 旋转视图 → 眼格 的换算，逆运算写在 VRDepthFeed.buildMap 里，两处必须同步改：
// 不同步的话深度会和它的彩色帧错着 90°，而画面看着"还是有立体感"，指标一条都不报错。
kernel void kScale(texture2d<float, access::sample> src [[texture(0)]],
                   texture2d<float, access::write>   dst [[texture(1)]],
                   constant VRP& P [[buffer(0)]],
                   uint2 g [[thread_position_in_grid]]) {
    if (g.x >= P.MW || g.y >= P.MH) return;
    float rx = (float(g.x) + 0.5 - P.ox) / P.scale - 0.5;
    float ry = (float(g.y) + 0.5 - P.oy) / P.scale - 0.5;
    float ex, ey;
    if (P.rot == 1u) {
        // 旋转视图 R 的宽 = P.H、高 = P.W；R(rx, ry) = 眼(ry, P.H-1-rx)
        if (rx < -0.5 || rx > float(P.H) - 0.5 || ry < -0.5 || ry > float(P.W) - 0.5) {
            dst.write(float4(0.0, 0.0, 0.0, 0.0), g);
            return;
        }
        ex = ry;
        ey = float(P.H) - 1.0 - rx;
    } else {
        if (rx < -0.5 || rx > float(P.W) - 0.5 || ry < -0.5 || ry > float(P.H) - 0.5) {
            dst.write(float4(0.0, 0.0, 0.0, 0.0), g);
            return;
        }
        ex = rx;
        ey = ry;
    }
    float2 uv = float2((ex + 0.5) / float(P.W), (ey + 0.5) / float(P.H));
    dst.write(src.sample(lin, uv), g);
}

// 1) 后向 remap 两只眼 + 把 z 缓冲清成「没人写过」
kernel void kBack(texture2d<float, access::sample> src [[texture(0)]],
                  texture2d<float, access::write>  fbL [[texture(1)]],
                  texture2d<float, access::write>  fbR [[texture(2)]],
                  constant VRP& P [[buffer(0)]],
                  device atomic_uint* bestL [[buffer(1)]],
                  device atomic_uint* bestR [[buffer(2)]],
                  device const float* dn [[buffer(3)]],
                  uint2 g [[thread_position_in_grid]]) {
    if (g.x >= P.W || g.y >= P.H) return;
    uint idx = g.y * P.W + g.x;
    float dd = ddOf(dn, idx, P);
    float2 uv = float2((float(g.x) + 0.5) / float(P.W), (float(g.y) + 0.5) / float(P.H));
    float2 du = float2(dd / float(P.W), 0.0);
    fbL.write(src.sample(lin, uv - du), g);
    fbR.write(src.sample(lin, uv + du), g);
    atomic_store_explicit(bestL + idx, 0u, memory_order_relaxed);
    atomic_store_explicit(bestR + idx, 0u, memory_order_relaxed);
}

// 2) 前向 splat 的第一趟：只把「谁占这一格」记进 z 缓冲（近的赢）
kernel void kSplatDepth(constant VRP& P [[buffer(0)]],
                        device atomic_uint* bestL [[buffer(1)]],
                        device atomic_uint* bestR [[buffer(2)]],
                        device const float* dn [[buffer(3)]],
                        uint2 g [[thread_position_in_grid]]) {
    if (g.x >= P.W || g.y >= P.H) return;
    float dd = ddOf(dn, g.y * P.W + g.x, P);
    uint e = encOrder(dd);
    int dl = int(rint(float(g.x) + dd));
    int dr = int(rint(float(g.x) - dd));
    if (dl >= 0 && uint(dl) < P.W) {
        atomic_fetch_max_explicit(bestL + g.y * P.W + uint(dl), e, memory_order_relaxed);
    }
    if (dr >= 0 && uint(dr) < P.W) {
        atomic_fetch_max_explicit(bestR + g.y * P.W + uint(dr), e, memory_order_relaxed);
    }
}

// 3) 前向 splat 的第二趟：只有「自己就是赢家」的源像素才把颜色写进成片
kernel void kSplatColor(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write>  sbs [[texture(1)]],
                        constant VRP& P [[buffer(0)]],
                        device atomic_uint* bestL [[buffer(1)]],
                        device atomic_uint* bestR [[buffer(2)]],
                        device const float* dn [[buffer(3)]],
                        uint2 g [[thread_position_in_grid]]) {
    if (g.x >= P.W || g.y >= P.H) return;
    float dd = ddOf(dn, g.y * P.W + g.x, P);
    uint e = encOrder(dd);
    int dl = int(rint(float(g.x) + dd));
    int dr = int(rint(float(g.x) - dd));
    float4 c = src.read(g);
    if (dl >= 0 && uint(dl) < P.W && atomic_load_explicit(bestL + g.y * P.W + uint(dl), memory_order_relaxed) == e) {
        sbs.write(c, uint2(uint(dl), g.y));
    }
    if (dr >= 0 && uint(dr) < P.W && atomic_load_explicit(bestR + g.y * P.W + uint(dr), memory_order_relaxed) == e) {
        sbs.write(c, uint2(P.W + uint(dr), g.y));
    }
}

// 4) 合洞：z 缓冲还是 0 的格子拿后向那份填，同时数洞
kernel void kCombine(texture2d<float, access::read>  fbL [[texture(0)]],
                     texture2d<float, access::read>  fbR [[texture(1)]],
                     texture2d<float, access::write> sbs [[texture(2)]],
                     constant VRP& P [[buffer(0)]],
                     device atomic_uint* bestL [[buffer(1)]],
                     device atomic_uint* bestR [[buffer(2)]],
                     device const float* dn [[buffer(3)]],
                     device atomic_uint* holes [[buffer(4)]],
                     uint2 g [[thread_position_in_grid]]) {
    if (g.x >= P.W || g.y >= P.H) return;
    uint idx = g.y * P.W + g.x;
    if (atomic_load_explicit(bestL + idx, memory_order_relaxed) == 0u) {
        sbs.write(fbL.read(g), uint2(g.x, g.y));
        atomic_fetch_add_explicit(holes, 1u, memory_order_relaxed);
    }
    if (atomic_load_explicit(bestR + idx, memory_order_relaxed) == 0u) {
        sbs.write(fbR.read(g), uint2(P.W + g.x, g.y));
        atomic_fetch_add_explicit(holes, 1u, memory_order_relaxed);
    }
}

// 5) 色彩往返自检用：同尺寸整幅照抄，测「BGRA 进 → BGRA 出」字节是不是原样回来
kernel void kCopy(texture2d<float, access::read>  src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant VRP& P [[buffer(0)]],
                  uint2 g [[thread_position_in_grid]]) {
    if (g.x >= P.W || g.y >= P.H) return;
    dst.write(src.read(g), g);
}
