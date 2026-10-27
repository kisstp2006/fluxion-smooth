// SPDX-License-Identifier: BSD-2-Clause

//! Shader parts - in Fluxion Shader's language - that a program puts into
//! its own shaders before it uses them. Every name begins with `smooth` so
//! it meets none of the program's. A part reads no block of its own: what
//! it needs is given as arguments; one that reads a texture is made for the
//! texture the program names (`catmullRom`, `upsample`), so the program
//! keeps its slots.
//!
//! - `noise`: interleaved gradient noise, and a value moved on through time
//!   by the golden ratio.
//! - `reproject`: where a point of the world was on last frame's screen.
//! - `clip`: colours in YCoCg, and a gathered colour drawn back into the
//!   spread of its neighbours - what keeps history from ghosting.
//! - `filter`: how much a neighbour counts when blurring: by depth, by
//!   normal, by brightness, and the à-trous kernel's weights.
//! - `resolve`: temporal antialiasing's step - this frame's jittered
//!   picture added to what was gathered, taken back along each pixel's
//!   motion and clipped to its neighbours.

const std = @import("std");

pub const noise =
    \\// Interleaved gradient noise at a pixel, moved on by `frame`: from
    \\// nought to one, each pixel unlike its neighbours (Jimenez 2014).
    \\float smoothIgn(vec2 pixel, float frame) {
    \\    vec2 p = pixel + vec2(frame * 5.588238);
    \\    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
    \\}
    \\
    \\// A value from nought to one moved on by the golden ratio each frame:
    \\// blue noise's values over time, spread evenly.
    \\float smoothGolden(float value, float frame) {
    \\    return fract(value + frame * 0.61803398875);
    \\}
    \\
;

pub const reproject =
    \\// Where `world` was on last frame's screen, from minus one to one: through
    \\// last frame's view and projection.
    \\vec2 smoothPreviousNdc(vec3 world, mat4 previous_view_projection) {
    \\    vec4 seen = previous_view_projection * vec4(world, 1.0);
    \\    return seen.xy / max(abs(seen.w), 0.000001) * sign(seen.w);
    \\}
    \\
    \\// A place on the screen from minus one to one as a texture's from nought
    \\// to one: `flip` one where the texture's rows run downward.
    \\vec2 smoothNdcToUv(vec2 ndc, float flip) {
    \\    vec2 uv = ndc * 0.5 + vec2(0.5);
    \\    return vec2(uv.x, mix(uv.y, 1.0 - uv.y, flip));
    \\}
    \\
    \\// Whether a place from nought to one is on the screen.
    \\float smoothOnScreen(vec2 uv) {
    \\    return step(0.0, uv.x) * step(0.0, uv.y) * step(uv.x, 1.0) * step(uv.y, 1.0);
    \\}
    \\
;

pub const clip =
    \\// A colour as brightness and two differences of hue: YCoCg, where the
    \\// spread of a pixel's neighbours is a tighter box than in RGB.
    \\vec3 smoothToYCoCg(vec3 c) {
    \\    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
    \\}
    \\
    \\vec3 smoothFromYCoCg(vec3 c) {
    \\    float t = c.x - c.z;
    \\    return vec3(t + c.y, c.x + c.z, t - c.y);
    \\}
    \\
    \\// What was gathered, drawn straight toward the middle of the box its
    \\// neighbours spread over - `mean` give or take `gamma` times `sigma` -
    \\// until it is inside: what no longer belongs there goes, what does
    \\// stays (Salvi's variance clipping, Karis's clip toward the middle).
    \\vec3 smoothClip(vec3 history, vec3 mean, vec3 sigma, float gamma) {
    \\    vec3 extent = sigma * gamma + vec3(0.0001);
    \\    vec3 offset = history - mean;
    \\    vec3 units = abs(offset / extent);
    \\    float most = max(units.x, max(units.y, units.z));
    \\    if (most > 1.0) {
    \\        return mean + offset / most;
    \\    }
    \\    return history;
    \\}
    \\
    \\// How much a colour of brightness `luma` counts when colours are added
    \\// up: less the brighter it is, so one bright pixel does not flicker
    \\// through the rest (Karis 2014).
    \\float smoothLumaWeight(float luma) {
    \\    return 1.0 / (1.0 + max(luma, 0.0));
    \\}
    \\
;

pub const filter =
    \\// How much a neighbour at linear depth `other` counts for a pixel at
    \\// `here`: all of it at the same depth, less as they part, the more
    \\// sharply the larger `sharpness`.
    \\float smoothDepthWeight(float here, float other, float sharpness) {
    \\    return exp(-abs(here - other) * sharpness / max(abs(here), 0.0001));
    \\}
    \\
    \\// How much a neighbour facing `other` counts for a pixel facing `here`.
    \\float smoothNormalWeight(vec3 here, vec3 other, float power) {
    \\    return pow(max(dot(here, other), 0.0), power);
    \\}
    \\
    \\// How much a neighbour of brightness `other` counts for a pixel of
    \\// `here`: less the more they differ against `spread`.
    \\float smoothLuminanceWeight(float here, float other, float spread) {
    \\    return exp(-abs(here - other) / max(spread, 0.0001));
    \\}
    \\
    \\// The à-trous filter's 5 by 5 kernel - the B3 spline, one dimension's
    \\// weight times the other's - at `d` steps from the middle, -2 to 2.
    \\float smoothAtrous(float d) {
    \\    float a = abs(d);
    \\    if (a < 0.5) {
    \\        return 0.375;
    \\    }
    \\    if (a < 1.5) {
    \\        return 0.25;
    \\    }
    \\    return 0.0625;
    \\}
    \\
;

/// Every part that reads no texture, in the order they may go in.
pub const all = noise ++ reproject ++ clip ++ filter;

/// `vec4 <name>(vec2 uv, vec2 size)`: the texture `texture`, `size` texels
/// across, read at `uv` through a Catmull-Rom spline over its four by four
/// texels - five bilinear readings - so a picture read off its texels, as
/// last frame's is, stays sharp. Never below nought.
pub fn catmullRom(comptime name: []const u8, comptime texture: []const u8) []const u8 {
    return "// `" ++ texture ++ "` read through a Catmull-Rom spline at `uv`, `size` texels across.\n" ++
        "vec4 " ++ name ++ "(vec2 uv, vec2 size) {\n" ++
        \\    vec2 at = uv * size;
        \\    vec2 center = floor(at - vec2(0.5)) + vec2(0.5);
        \\    vec2 f = at - center;
        \\    vec2 f2 = f * f;
        \\    vec2 f3 = f2 * f;
        \\    vec2 w0 = f2 - f3 * 0.5 - f * 0.5;
        \\    vec2 w1 = f3 * 1.5 - f2 * 2.5 + vec2(1.0);
        \\    vec2 w2 = f2 * 2.0 - f3 * 1.5 + f * 0.5;
        \\    vec2 w3 = f3 * 0.5 - f2 * 0.5;
        \\    vec2 w12 = w1 + w2;
        \\    vec2 t0 = (center - vec2(1.0)) / size;
        \\    vec2 t3 = (center + vec2(2.0)) / size;
        \\    vec2 t12 = (center + w2 / w12) / size;
        \\
    ++
        "    vec4 sum = sample_level(" ++ texture ++ ", vec2(t12.x, t0.y), 0.0) * (w12.x * w0.y)\n" ++
        "        + sample_level(" ++ texture ++ ", vec2(t0.x, t12.y), 0.0) * (w0.x * w12.y)\n" ++
        "        + sample_level(" ++ texture ++ ", t12, 0.0) * (w12.x * w12.y)\n" ++
        "        + sample_level(" ++ texture ++ ", vec2(t3.x, t12.y), 0.0) * (w3.x * w12.y)\n" ++
        "        + sample_level(" ++ texture ++ ", vec2(t12.x, t3.y), 0.0) * (w12.x * w3.y);\n" ++
        \\    float total = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
        \\    return max(sum / total, vec4(0.0));
        \\}
        \\
        \\
    ;
}

/// `vec4 <name>(vec2 uv, vec2 low_size, float depth)`: what an effect drawn
/// at a lower size - `low` and its linear depths `low_depth`, `low_size`
/// texels across - gives a pixel at linear depth `depth`: its four nearest
/// texels by how near they are and how near their depth is, or where none
/// is near in depth - an edge - the one nearest in depth. Wants `filter`.
pub fn upsample(comptime name: []const u8, comptime low: []const u8, comptime low_depth: []const u8) []const u8 {
    return "// `" ++ low ++ "` brought up to this pixel by `" ++ low_depth ++ "`.\n" ++
        "vec4 " ++ name ++ "(vec2 uv, vec2 low_size, float depth) {\n" ++
        \\    vec2 at = uv * low_size - vec2(0.5);
        \\    vec2 base = floor(at);
        \\    vec2 f = at - base;
        \\    vec4 sum = vec4(0.0);
        \\    float total = 0.0;
        \\    float nearest = 1000000000.0;
        \\    vec2 nearest_uv = (base + vec2(0.5)) / low_size;
        \\    for (int i = 0; i < 4; i = i + 1) {
        \\        vec2 corner = vec2(float(i - (i / 2) * 2), float(i / 2));
        \\        vec2 texel = (base + corner + vec2(0.5)) / low_size;
        \\        vec2 near = mix(vec2(1.0) - f, f, corner);
        \\
    ++
        "        float d = sample_level(" ++ low_depth ++ ", texel, 0.0).r;\n" ++
        "        float w = near.x * near.y * smoothDepthWeight(depth, d, 32.0);\n" ++
        "        sum = sum + sample_level(" ++ low ++ ", texel, 0.0) * w;\n" ++
        \\        total = total + w;
        \\        float apart = abs(depth - d);
        \\        if (apart < nearest) {
        \\            nearest = apart;
        \\            nearest_uv = texel;
        \\        }
        \\    }
        \\    if (total < 0.001) {
        \\
    ++
        "        return sample_level(" ++ low ++ ", nearest_uv, 0.0);\n" ++
        \\    }
        \\    return sum / total;
        \\}
        \\
        \\
    ;
}

/// `vec4 <name>(vec2 uv, vec2 size, vec2 jitter, float blend)`: temporal
/// antialiasing's step for the pixel at `uv` of a picture `size` texels
/// across - this frame's `current`, drawn through a projection moved by
/// `jitter` pixels (in the texture's own directions), added to `history`,
/// what was gathered up to last frame. `blend` is how much of a still
/// pixel this frame makes, a tenth or so; one where there is no history.
///
/// - The pixel is this frame's three by three neighbours weighted by how
///   near each was drawn to the pixel's middle once the jitter is taken
///   off (Karis 2014), so the picture does not shake with it.
/// - It is taken back along the motion - `motion`'s `xy`, from nought to
///   one in the texture's own measure - of the neighbour nearest the
///   camera by `depth`'s `channel` (linear, nought for nothing drawn): an
///   edge moving over a far wall drags no trail.
/// - History is read through a Catmull-Rom spline, and clipped into the
///   box its neighbours spread over in YCoCg (Salvi, Karis), wider where
///   the pixel stands still and narrower as it moves. Off the screen it is
///   let go of.
/// - Colours are added up weighted by brightness (`smoothLumaWeight`), so
///   a bright speck does not flicker; a moving pixel takes more of this
///   frame, which keeps it sharp.
///
/// The alpha is this frame's. Wants `clip` and `reproject`.
pub fn resolve(comptime name: []const u8, comptime current: []const u8, comptime history: []const u8, comptime motion: []const u8, comptime depth: []const u8, comptime channel: []const u8) []const u8 {
    return catmullRom(name ++ "History", history) ++
        "// Temporal antialiasing: `" ++ current ++ "` added to `" ++ history ++ "` along `" ++ motion ++ "`.\n" ++
        "vec4 " ++ name ++ "(vec2 uv, vec2 size, vec2 jitter, float blend) {\n" ++
        \\    vec2 texel = vec2(1.0) / size;
        \\    vec3 m1 = vec3(0.0);
        \\    vec3 m2 = vec3(0.0);
        \\    vec3 filtered = vec3(0.0);
        \\    float filtered_weight = 0.0;
        \\    float nearest = 1000000000.0;
        \\    vec2 nearest_uv = uv;
        \\
    ++
        "    vec4 middle = sample_level(" ++ current ++ ", uv, 0.0);\n" ++
        \\    for (int i = 0; i < 9; i = i + 1) {
        \\        vec2 o = vec2(float(i - (i / 3) * 3 - 1), float(i / 3 - 1));
        \\        vec2 at = uv + o * texel;
        \\
    ++
        "        vec3 c = smoothToYCoCg(max(sample_level(" ++ current ++ ", at, 0.0).rgb, vec3(0.0)));\n" ++
        \\        c = c * smoothLumaWeight(c.x);
        \\        m1 = m1 + c;
        \\        m2 = m2 + c * c;
        \\        vec2 off = o - jitter;
        \\        float w = exp(-2.29 * dot(off, off));
        \\        filtered = filtered + c * w;
        \\        filtered_weight = filtered_weight + w;
        \\
    ++
        "        float z = sample_level(" ++ depth ++ ", at, 0.0)." ++ channel ++ ";\n" ++
        \\        if (z <= 0.0) {
        \\            z = 1000000000.0;
        \\        }
        \\        if (z < nearest) {
        \\            nearest = z;
        \\            nearest_uv = at;
        \\        }
        \\    }
        \\    vec3 mean = m1 / 9.0;
        \\    vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
        \\    vec3 now = filtered / max(filtered_weight, 0.0001);
        \\
    ++
        "    vec2 moved = sample_level(" ++ motion ++ ", nearest_uv, 0.0).xy;\n" ++
        \\    vec2 back = uv - moved;
        \\    float speed = clamp(length(moved * size) * 0.125, 0.0, 1.0);
        \\    float alpha = clamp(mix(blend, max(blend, 0.25), speed), 0.0, 1.0);
        \\    if (smoothOnScreen(back) < 0.5) {
        \\        alpha = 1.0;
        \\    }
        \\
    ++
        "    vec3 before = smoothToYCoCg(" ++ name ++ "History(back, size).rgb);\n" ++
        \\    before = before * smoothLumaWeight(before.x);
        \\    before = smoothClip(before, mean, sigma, mix(1.25, 0.85, speed));
        \\    vec3 gathered = mix(before, now, alpha);
        \\    gathered = gathered / max(1.0 - gathered.x, 0.0001);
        \\    return vec4(max(smoothFromYCoCg(gathered), vec3(0.0)), middle.a);
        \\}
        \\
        \\
    ;
}
