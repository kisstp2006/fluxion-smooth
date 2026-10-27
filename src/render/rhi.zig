// SPDX-License-Identifier: BSD-2-Clause

//! The GPU side of Fluxion Smooth, through Fluxion RHI: the blue noise as a
//! texture, and the pictures each view keeps from frame to frame - two of
//! each, one read while the other is drawn, swapped every frame.
//!
//! ```zig
//! const noise = try smooth_rhi.blueNoise(&device);
//! var pictures: smooth_rhi.Histories = .{};
//! const pair = try pictures.pair(gpa, &device, .{ .view = camera_key, .slot = 0 }, width, height, .rgba16_float);
//! // read pair.previous, draw into pair.next
//! pictures.endFrame(gpa, &device);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const rhi = @import("fluxion_rhi");
const smooth = @import("fluxion_smooth");

/// The blue noise as a one-channel texture, `noise.size` texels across: read
/// it with a nearest, repeating sampler, or at texel middles.
pub fn blueNoise(device: *rhi.Device) rhi.Error!rhi.Texture {
    return device.createTexture(.{
        .width = smooth.noise.size,
        .height = smooth.noise.size,
        .format = .r8_unorm,
        .data = smooth.noise.blue_noise,
        .label = "fluxion-smooth blue noise",
    });
}

/// Which picture of which view: a view keeps as many as its effects
/// gather - its colour for antialiasing, its fog, its clouds.
pub const Key = struct {
    view: u64,
    slot: u32 = 0,
};

/// The two pictures of a key this frame.
pub const Pair = struct {
    /// What was gathered up to last frame.
    previous: rhi.Texture,
    /// What this frame gathers into.
    next: rhi.Texture,
    /// The pictures were made this frame: `previous` holds nothing yet.
    fresh: bool,
};

pub const Histories = struct {
    kept: std.AutoArrayHashMapUnmanaged(Key, Kept) = .empty,
    frame: u64 = 0,

    const Kept = struct {
        textures: [2]rhi.Texture,
        width: u32,
        height: u32,
        format: rhi.Format,
        /// Which of the two is `next` this frame.
        next: u1 = 0,
        /// The frame it was last asked for.
        used: u64 = 0,
    };

    /// How many frames a pair may go unasked for before it is let go of.
    pub const keep_for = 3;

    pub fn deinit(self: *Histories, gpa: Allocator, device: *rhi.Device) void {
        for (self.kept.values()) |held| for (held.textures) |t| device.destroyTexture(t);
        self.kept.deinit(gpa);
    }

    /// The pair of `key` for a picture `width` by `height` of `format`: made
    /// the first time, and again when the size or format changes. Asked for
    /// twice in a frame, it is the same pair both times.
    pub fn pair(self: *Histories, gpa: Allocator, device: *rhi.Device, key: Key, width: u32, height: u32, format: rhi.Format) (Allocator.Error || rhi.Error)!Pair {
        const found = try self.kept.getOrPut(gpa, key);
        var fresh = false;
        if (found.found_existing) {
            const held = found.value_ptr;
            if (held.width != width or held.height != height or held.format != format) {
                for (held.textures) |t| device.destroyTexture(t);
                found.value_ptr.* = try make(device, width, height, format);
                fresh = true;
            } else if (held.used != self.frame) {
                held.next ^= 1;
            }
        } else {
            errdefer _ = self.kept.swapRemove(key);
            found.value_ptr.* = try make(device, width, height, format);
            fresh = true;
        }
        const held = found.value_ptr;
        held.used = self.frame;
        return .{ .previous = held.textures[held.next ^ 1], .next = held.textures[held.next], .fresh = fresh };
    }

    fn make(device: *rhi.Device, width: u32, height: u32, format: rhi.Format) rhi.Error!Kept {
        var textures: [2]rhi.Texture = undefined;
        for (&textures, 0..) |*t, i| {
            t.* = device.createTexture(.{
                .width = width,
                .height = height,
                .format = format,
                .usage = .{ .sampled = true, .render_target = true },
                .label = if (i == 0) "fluxion-smooth history a" else "fluxion-smooth history b",
            }) catch |err| {
                if (i == 1) device.destroyTexture(textures[0]);
                return err;
            };
        }
        return .{ .textures = textures, .width = width, .height = height, .format = format };
    }

    /// The frame is over: the pairs not asked for lately let go of.
    pub fn endFrame(self: *Histories, device: *rhi.Device) void {
        var i: usize = 0;
        while (i < self.kept.count()) {
            const held = self.kept.values()[i];
            if (self.frame - held.used >= keep_for) {
                for (held.textures) |t| device.destroyTexture(t);
                self.kept.swapRemoveAt(i);
            } else i += 1;
        }
        self.frame += 1;
    }
};

const testing = std.testing;
const shader = @import("fluxion_shader");

fn nullDevice() !rhi.Device {
    return rhi.Device.init(testing.allocator, .{ .backend = .none });
}

test "the blue noise is a texture of its size" {
    var d = try nullDevice();
    defer d.deinit();
    const t = try blueNoise(&d);
    defer d.destroyTexture(t);
    try testing.expect(!t.isNone());
}

test "a pair swaps each frame, is the same pair twice in a frame, is made again at another size, and goes when unasked" {
    var d = try nullDevice();
    defer d.deinit();
    var pictures: Histories = .{};
    defer pictures.deinit(testing.allocator, &d);
    const key: Key = .{ .view = 1 };

    const first = try pictures.pair(testing.allocator, &d, key, 64, 32, .rgba16_float);
    try testing.expect(first.fresh);
    const again = try pictures.pair(testing.allocator, &d, key, 64, 32, .rgba16_float);
    try testing.expect(std.meta.eql(first.next, again.next) and !again.fresh);
    pictures.endFrame(&d);

    const second = try pictures.pair(testing.allocator, &d, key, 64, 32, .rgba16_float);
    try testing.expect(!second.fresh);
    try testing.expect(std.meta.eql(second.previous, first.next));
    try testing.expect(std.meta.eql(second.next, first.previous));
    pictures.endFrame(&d);

    try testing.expect((try pictures.pair(testing.allocator, &d, key, 128, 32, .rgba16_float)).fresh);
    // The frame it was asked in ends, and then that many frames without it.
    pictures.endFrame(&d);
    for (0..Histories.keep_for - 1) |_| pictures.endFrame(&d);
    try testing.expectEqual(@as(usize, 1), pictures.kept.count());
    pictures.endFrame(&d);
    try testing.expectEqual(@as(usize, 0), pictures.kept.count());
}

/// A shader that calls every part, for the compiler to check on every
/// backend.
const every_part = "attribute vec2 corner : 0;\n" ++
    "varying vec2 uv;\n" ++
    "uniform Knobs : 0 { mat4 previous; vec4 knobs; }\n" ++
    "texture2d history : 0;\n" ++
    "texture2d low : 1;\n" ++
    "texture2d low_depth : 2;\n" ++
    "texture2d motion : 3;\n" ++
    smooth.parts.all ++
    smooth.parts.catmullRom("smoothHistory", "history") ++
    smooth.parts.upsample("smoothUp", "low", "low_depth") ++
    smooth.parts.resolve("smoothResolve", "low", "history", "motion", "low_depth", "z") ++
    \\vertex {
    \\    uv = corner;
    \\    position = vec4(corner * 2.0 - vec2(1.0), 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    float n = smoothIgn(uv * 512.0, knobs.x) + smoothGolden(knobs.y, knobs.x);
    \\    vec2 back = smoothNdcToUv(smoothPreviousNdc(vec3(uv, knobs.z), previous), knobs.w) * smoothOnScreen(uv);
    \\    vec3 c = smoothToYCoCg(smoothHistory(back, vec2(512.0)).rgb);
    \\    c = smoothClip(c, vec3(0.5), vec3(0.1), 1.25) * smoothLumaWeight(c.x);
    \\    float w = smoothDepthWeight(1.0, n, 8.0) * smoothNormalWeight(vec3(0.0, 1.0, 0.0), vec3(0.0, 0.8, 0.6), 8.0)
    \\        * smoothLuminanceWeight(0.5, n, 0.2) * smoothAtrous(1.0);
    \\    target = vec4(smoothFromYCoCg(c) * w, 1.0) + smoothUp(uv, vec2(256.0), knobs.z) + smoothResolve(uv, vec2(512.0), knobs.xy, knobs.w);
    \\}
    \\
;

test "every part compiles for every backend" {
    var said: std.Io.Writer.Allocating = .init(testing.allocator);
    defer said.deinit();
    var module = shader.compile(testing.allocator, every_part, &said.writer) catch |err| {
        std.debug.print("{s}\n", .{said.written()});
        return err;
    };
    defer module.deinit();
    try testing.expect(module.glsl.fragment.len > 0 and module.hlsl.fragment.len > 0 and module.glsl_es.fragment.len > 0);
}
