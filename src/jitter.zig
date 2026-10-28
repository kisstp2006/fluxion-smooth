// SPDX-License-Identifier: BSD-2-Clause

//! Where in its pixel each frame is drawn from: a camera's projection moved
//! by less than a pixel, a little differently each frame, so that frames
//! added up see the whole of each pixel - what temporal antialiasing gathers.
//!
//! The offsets are the Halton sequence in bases two and three, which covers
//! a square evenly however many of its points are taken, and goes round a
//! cycle of `length` frames.
//!
//! ```zig
//! const jitter: Jitter = .{};
//! const drawn = jitter.apply(projection, frame, width, height);
//! ```

const std = @import("std");
const math = @import("fluxion_math");
const Mat4 = math.Mat4;

/// The `index`th number of the Halton sequence in `base`, from nought to
/// one: index one is a half in base two, two a quarter, three three
/// quarters.
pub fn halton(index: u32, base: u32) f32 {
    var f: f32 = 1;
    var r: f32 = 0;
    var i = index;
    const b: f32 = @floatFromInt(base);
    while (i > 0) {
        f /= b;
        r += f * @as(f32, @floatFromInt(i % base));
        i /= base;
    }
    return r;
}

pub const Jitter = struct {
    /// How many frames before the offsets come round again: eight is what
    /// most engines take, sixteen covers a pixel more finely.
    length: u32 = 8,

    /// For a picture gathered `ratio` times as large across as it is drawn:
    /// a cycle long enough that every gathered pixel has drawn ones come
    /// near it - eight frames times the ratio squared (AMD's FSR 2), from
    /// eight to sixty-four.
    pub fn upscaling(ratio: f32) Jitter {
        const wanted = @ceil(8 * @max(ratio, 1) * @max(ratio, 1));
        return .{ .length = @intFromFloat(std.math.clamp(wanted, 8, 64)) };
    }

    /// Frame `frame`'s offset, in pixels, each from minus a half to a half.
    pub fn offset(self: Jitter, frame: u64) [2]f32 {
        const at: u32 = @intCast(frame % @max(self.length, 1) + 1);
        return .{ halton(at, 2) - 0.5, halton(at, 3) - 0.5 };
    }

    /// `projection` moved by frame `frame`'s offset on a target `width` by
    /// `height` pixels: the clip space moved, so that after the divide every
    /// point lands that part of a pixel aside - for a perspective and an
    /// orthographic projection alike.
    pub fn apply(self: Jitter, projection: Mat4, frame: u64, width: f32, height: f32) Mat4 {
        const o = self.offset(frame);
        return Mat4.fromTranslation(.init(2 * o[0] / @max(width, 1), 2 * o[1] / @max(height, 1), 0)).mul(projection);
    }
};

const testing = std.testing;

test "the Halton sequence halves, then fills between" {
    try testing.expectEqual(@as(f32, 0.5), halton(1, 2));
    try testing.expectEqual(@as(f32, 0.25), halton(2, 2));
    try testing.expectEqual(@as(f32, 0.75), halton(3, 2));
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), halton(1, 3), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), halton(2, 3), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 9.0), halton(3, 3), 1e-6);
}

test "a cycle's offsets stay inside the pixel, average to its middle, and come round again" {
    const jitter: Jitter = .{ .length = 16 };
    var sum: [2]f32 = .{ 0, 0 };
    for (0..16) |frame| {
        const o = jitter.offset(frame);
        try testing.expect(@abs(o[0]) <= 0.5 and @abs(o[1]) <= 0.5);
        sum[0] += o[0];
        sum[1] += o[1];
    }
    try testing.expect(@abs(sum[0] / 16) < 0.05 and @abs(sum[1] / 16) < 0.05);
    try testing.expectEqual(jitter.offset(3), jitter.offset(19));
}

test "a point drawn through the moved projection lands its offset in pixels aside" {
    const jitter: Jitter = .{};
    const width: f32 = 1280;
    const height: f32 = 720;
    const projection = math.perspective(.{ .fov_y = 1.2, .aspect = width / height, .near = 0.1, .far = 100, .clip = .d3d });
    const point: math.Vec3 = .init(0.4, -0.2, -5);
    const plain = projection.project(point).?;
    for (0..8) |frame| {
        const moved = jitter.apply(projection, frame, width, height).project(point).?;
        const o = jitter.offset(frame);
        try testing.expectApproxEqAbs(o[0], (moved.x - plain.x) * width / 2, 1e-3);
        try testing.expectApproxEqAbs(o[1], (moved.y - plain.y) * height / 2, 1e-3);
        try testing.expectApproxEqAbs(plain.z, moved.z, 1e-6);
    }
}

test "a picture gathered larger than it is drawn takes a longer cycle" {
    try testing.expectEqual(@as(u32, 8), Jitter.upscaling(1).length);
    try testing.expectEqual(@as(u32, 8), Jitter.upscaling(0.5).length);
    try testing.expectEqual(@as(u32, 18), Jitter.upscaling(1.5).length);
    try testing.expectEqual(@as(u32, 32), Jitter.upscaling(2).length);
    try testing.expectEqual(@as(u32, 64), Jitter.upscaling(4).length);
}
