// SPDX-License-Identifier: BSD-2-Clause

//! `zig build blue-noise`: the blue noise made again and written to the path
//! given - `src/blue_noise.bin`, which the library embeds.

const std = @import("std");
const noise = @import("fluxion_smooth").noise;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.NoPathGiven;
    const made = try noise.makeBlueNoise(gpa, noise.size, 1);
    defer gpa.free(made);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = made });
}
