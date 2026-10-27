// SPDX-License-Identifier: BSD-2-Clause

//! Noise for spreading samples so that what is left of their error is fine
//! and even, and goes away when frames are added up or neighbours blurred.
//!
//! - **Interleaved gradient noise** (Jimenez, *Next Generation Post
//!   Processing in Call of Duty: Advanced Warfare*, 2014): a formula, no
//!   texture, made for temporal antialiasing - each pixel differs from its
//!   neighbours, and moves on from frame to frame. `ign` is it on the CPU,
//!   `parts.noise` in a shader.
//! - **Blue noise**: a 64 by 64 picture of every value from nought to 255
//!   sixteen times, spread so that no two near pixels are alike - no low
//!   frequencies, so what it dithers looks like fine grain, not clumps.
//!   Made once by void-and-cluster (Ulichney, 1993) and kept in
//!   `blue_noise.bin`; `zig build blue-noise` makes it again. Moved on each
//!   frame by the golden ratio, each pixel's values over time are spread
//!   evenly too - what spatiotemporal blue noise (NVIDIA, 2022) gives, made
//!   here rather than shipped.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How many pixels across the blue noise is.
pub const size = 64;

/// The blue noise, a byte a pixel, row by row.
pub const blue_noise: *const [size * size]u8 = @embedFile("blue_noise.bin");

/// What a value is moved on by each frame: the golden ratio's fraction.
pub const golden = 0.61803398875;

/// Interleaved gradient noise at a pixel's whole coordinates, moved on by
/// `frame`: from nought to one.
pub fn ign(x: f32, y: f32, frame: f32) f32 {
    const px = x + frame * 5.588238;
    const py = y + frame * 5.588238;
    return fract(52.9829189 * fract(px * 0.06711056 + py * 0.00583715));
}

/// The blue noise at a pixel, moved on by `frame`: from nought to one.
pub fn blueAt(x: u32, y: u32, frame: u64) f32 {
    const v: f32 = (@as(f32, @floatFromInt(blue_noise[(y % size) * size + (x % size)])) + 0.5) / 256.0;
    return fract(v + @as(f32, @floatFromInt(frame % 4096)) * golden);
}

fn fract(v: f32) f32 {
    return v - @floor(v);
}

/// Blue noise `side` pixels across, made by void-and-cluster: each pixel's
/// rank in the order the pattern was filled, scaled to a byte. The caller's.
pub fn makeBlueNoise(gpa: Allocator, side: u32, seed: u64) Allocator.Error![]u8 {
    const n = side * side;
    var maker: Maker = try .init(gpa, side);
    defer maker.deinit(gpa);
    const ranks = try gpa.alloc(u32, n);
    defer gpa.free(ranks);

    // A tenth of the pixels, at random, then moved until no one is in a
    // tighter cluster than the largest void: the prototype.
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    const first = n / 10;
    var placed: u32 = 0;
    while (placed < first) {
        const at = random.uintLessThan(u32, n);
        if (maker.on[at]) continue;
        maker.set(at, true);
        placed += 1;
    }
    while (true) {
        const tight = maker.tightest();
        maker.set(tight, false);
        const hole = maker.emptiest();
        if (hole == tight) {
            maker.set(tight, true);
            break;
        }
        maker.set(hole, true);
    }
    const prototype = try gpa.dupe(bool, maker.on);
    defer gpa.free(prototype);
    const kept = try gpa.dupe(f32, maker.energy);
    defer gpa.free(kept);

    // The prototype's points ranked by taking the tightest first, last.
    var rank = first;
    while (rank > 0) {
        rank -= 1;
        const tight = maker.tightest();
        maker.set(tight, false);
        ranks[tight] = rank;
    }
    // From the prototype again, the rest by filling the largest void.
    @memcpy(maker.on, prototype);
    @memcpy(maker.energy, kept);
    rank = first;
    while (rank < n) : (rank += 1) {
        const hole = maker.emptiest();
        maker.set(hole, true);
        ranks[hole] = rank;
    }

    const out = try gpa.alloc(u8, n);
    for (ranks, out) |r, *v| v.* = @intCast(@as(u64, r) * 256 / n);
    return out;
}

/// What void-and-cluster keeps: which pixels are on, and how crowded each
/// place is - the sum of a Gaussian round every pixel that is on, on a
/// torus, so the pattern tiles.
const Maker = struct {
    side: u32,
    on: []bool,
    energy: []f32,
    /// The Gaussian at each offset, on the torus.
    kernel: []f32,

    const sigma = 1.5;

    fn init(gpa: Allocator, side: u32) Allocator.Error!Maker {
        const n = side * side;
        const kernel = try gpa.alloc(f32, n);
        for (0..side) |y| for (0..side) |x| {
            const dx = @as(f32, @floatFromInt(@min(x, side - x)));
            const dy = @as(f32, @floatFromInt(@min(y, side - y)));
            kernel[y * side + x] = @exp(-(dx * dx + dy * dy) / (2 * sigma * sigma));
        };
        const on = try gpa.alloc(bool, n);
        @memset(on, false);
        const energy = try gpa.alloc(f32, n);
        @memset(energy, 0);
        return .{ .side = side, .on = on, .energy = energy, .kernel = kernel };
    }

    fn deinit(self: *Maker, gpa: Allocator) void {
        gpa.free(self.on);
        gpa.free(self.energy);
        gpa.free(self.kernel);
    }

    fn set(self: *Maker, at: u32, on: bool) void {
        self.on[at] = on;
        const side = self.side;
        const ax = at % side;
        const ay = at / side;
        const sign: f32 = if (on) 1 else -1;
        for (0..side) |y| for (0..side) |x| {
            const dx = (x + side - ax) % side;
            const dy = (y + side - ay) % side;
            self.energy[y * side + x] += sign * self.kernel[dy * side + dx];
        };
    }

    /// The pixel that is on where it is most crowded.
    fn tightest(self: *const Maker) u32 {
        var best: u32 = 0;
        var most = -std.math.floatMax(f32);
        for (self.energy, self.on, 0..) |e, on, i| if (on and e > most) {
            most = e;
            best = @intCast(i);
        };
        return best;
    }

    /// The pixel that is off where it is least crowded.
    fn emptiest(self: *const Maker) u32 {
        var best: u32 = 0;
        var least = std.math.floatMax(f32);
        for (self.energy, self.on, 0..) |e, on, i| if (!on and e < least) {
            least = e;
            best = @intCast(i);
        };
        return best;
    }
};

const testing = std.testing;

test "interleaved gradient noise stays between nought and one, and moves on with the frame" {
    var moved: usize = 0;
    for (0..16) |y| for (0..16) |x| {
        const a = ign(@floatFromInt(x), @floatFromInt(y), 0);
        const b = ign(@floatFromInt(x), @floatFromInt(y), 1);
        try testing.expect(a >= 0 and a < 1 and b >= 0 and b < 1);
        if (a != b) moved += 1;
    };
    try testing.expect(moved > 250);
}

test "the blue noise kept is what void-and-cluster makes, each value as often as every other" {
    const made = try makeBlueNoise(testing.allocator, size, 1);
    defer testing.allocator.free(made);
    try testing.expectEqualSlices(u8, made, blue_noise);
    var counts: [256]u32 = @splat(0);
    for (blue_noise) |v| counts[v] += 1;
    for (counts) |c| try testing.expectEqual(@as(u32, size * size / 256), c);
}

test "the blue noise has no clumps: its four by four blocks average near the middle, far nearer than white noise's" {
    var sum_squares: f32 = 0;
    var blocks: f32 = 0;
    var by: u32 = 0;
    while (by < size) : (by += 4) {
        var bx: u32 = 0;
        while (bx < size) : (bx += 4) {
            var sum: f32 = 0;
            for (0..4) |y| for (0..4) |x| {
                sum += @floatFromInt(blue_noise[(by + y) * size + bx + x]);
            };
            const off = sum / 16 - 127.5;
            sum_squares += off * off;
            blocks += 1;
        }
    }
    // White noise's block means spread about 18.5 either side.
    try testing.expect(@sqrt(sum_squares / blocks) < 10);
}

test "a pixel's blue noise over frames spreads evenly, by the golden ratio" {
    var buckets: [8]u32 = @splat(0);
    for (0..64) |frame| buckets[@intFromFloat(blueAt(5, 9, frame) * 8)] += 1;
    for (buckets) |b| try testing.expect(b >= 6 and b <= 10);
}
