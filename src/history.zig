// SPDX-License-Identifier: BSD-2-Clause

//! What each view saw last frame, for what is gathered over frames: where
//! its camera was - the view and projection a point is taken back through,
//! to find where it was drawn then - and whether what it gathered still
//! holds. A view is anything drawn into a picture of its own: a game's
//! camera, a picture in picture, an editor's view of its scene. Each is
//! known by a key of the program's choosing.
//!
//! What was gathered is let go of - `Seen.fresh` - when the view is new, its
//! picture changed size, or the program said it cut away (`cut`): a camera
//! switched, a player sent across the map. A view not seen for a while is
//! forgotten, and its pictures with it.
//!
//! ```zig
//! tracker.beginFrame();
//! const seen = try tracker.see(gpa, camera_key, view_projection, width, height);
//! // seen.previous: last frame's; seen.fresh: start gathering again.
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("fluxion_math");
const Mat4 = math.Mat4;

/// How many frames a view may go unseen before it is forgotten.
pub const forget_after = 8;

pub const Tracker = struct {
    views: std.AutoArrayHashMapUnmanaged(u64, View) = .empty,
    /// Counts up each frame from one: what noise and jitter move on by.
    frame: u64 = 0,

    pub const View = struct {
        view_projection: Mat4,
        /// What it was told it saw last frame, the first time it was seen
        /// this frame: what it is told again if seen again this frame.
        previous: Mat4,
        width: u32,
        height: u32,
        /// How many frames in a row it has gathered.
        frames: u32 = 0,
        /// The frame it was last seen in.
        seen: u64 = 0,
        /// Told to start again: `cut`.
        cut: bool = false,
    };

    /// What a view is told as a frame draws it.
    pub const Seen = struct {
        /// Last frame's view and projection; this frame's for a fresh view.
        previous: Mat4,
        /// What it gathered does not hold: start again.
        fresh: bool,
        /// How many frames in a row it has gathered, this one counted.
        frames: u32,
    };

    pub fn deinit(self: *Tracker, gpa: Allocator) void {
        self.views.deinit(gpa);
    }

    /// A frame begins: the views not seen lately forgotten.
    pub fn beginFrame(self: *Tracker) void {
        self.frame += 1;
        var i: usize = 0;
        while (i < self.views.count()) {
            if (self.frame - self.views.values()[i].seen > forget_after) self.views.swapRemoveAt(i) else i += 1;
        }
    }

    /// View `key` drawn this frame with `view_projection` into a picture
    /// `width` by `height`.
    pub fn see(self: *Tracker, gpa: Allocator, key: u64, view_projection: Mat4, width: u32, height: u32) Allocator.Error!Seen {
        const found = try self.views.getOrPut(gpa, key);
        if (!found.found_existing) {
            found.value_ptr.* = .{ .view_projection = view_projection, .previous = view_projection, .width = width, .height = height, .frames = 1, .seen = self.frame };
            return .{ .previous = view_projection, .fresh = true, .frames = 1 };
        }
        const view = found.value_ptr;
        // Seen again this frame - a picture of the frame taken after it was
        // drawn: told what it was told the first time.
        if (view.seen == self.frame and !view.cut and view.width == width and view.height == height) {
            view.view_projection = view_projection;
            return .{ .previous = view.previous, .fresh = view.frames == 1, .frames = view.frames };
        }
        const fresh = view.cut or view.width != width or view.height != height or self.frame - view.seen > 1;
        const previous = if (fresh) view_projection else view.view_projection;
        view.* = .{ .view_projection = view_projection, .previous = previous, .width = width, .height = height, .frames = if (fresh) 1 else view.frames + 1, .seen = self.frame };
        return .{ .previous = previous, .fresh = fresh, .frames = view.frames };
    }

    /// View `key` cut away: what it gathered is let go of next frame.
    pub fn cut(self: *Tracker, key: u64) void {
        if (self.views.getPtr(key)) |view| view.cut = true;
    }

    /// Whether view `key` is known now: for a program letting go of its
    /// pictures.
    pub fn knows(self: *const Tracker, key: u64) bool {
        return self.views.contains(key);
    }
};

const testing = std.testing;

test "a view is fresh when new, resized or cut, and gathers frame after frame otherwise, told where it was" {
    var tracker: Tracker = .{};
    defer tracker.deinit(testing.allocator);
    const a = Mat4.fromTranslation(.init(1, 0, 0));
    const b = Mat4.fromTranslation(.init(2, 0, 0));

    tracker.beginFrame();
    const first = try tracker.see(testing.allocator, 7, a, 640, 480);
    try testing.expect(first.fresh and first.frames == 1);

    tracker.beginFrame();
    const second = try tracker.see(testing.allocator, 7, b, 640, 480);
    try testing.expect(!second.fresh and second.frames == 2);
    try testing.expect(second.previous.eql(a));

    tracker.beginFrame();
    try testing.expect((try tracker.see(testing.allocator, 7, b, 800, 480)).fresh);

    tracker.cut(7);
    tracker.beginFrame();
    const after = try tracker.see(testing.allocator, 7, a, 800, 480);
    try testing.expect(after.fresh and after.previous.eql(a));
    tracker.beginFrame();
    try testing.expect(!(try tracker.see(testing.allocator, 7, a, 800, 480)).fresh);
}

test "a view seen twice in a frame - its picture taken after it was drawn - is told the same both times" {
    var tracker: Tracker = .{};
    defer tracker.deinit(testing.allocator);
    const a = Mat4.fromTranslation(.init(1, 0, 0));
    const b = Mat4.fromTranslation(.init(2, 0, 0));
    tracker.beginFrame();
    _ = try tracker.see(testing.allocator, 3, a, 64, 64);
    tracker.beginFrame();
    const first = try tracker.see(testing.allocator, 3, b, 64, 64);
    const again = try tracker.see(testing.allocator, 3, b, 64, 64);
    try testing.expect(first.previous.eql(a) and again.previous.eql(a));
    try testing.expect(!again.fresh and again.frames == first.frames);
}

test "a view missed for a frame starts again, and one unseen for long is forgotten" {
    var tracker: Tracker = .{};
    defer tracker.deinit(testing.allocator);
    tracker.beginFrame();
    _ = try tracker.see(testing.allocator, 1, .identity, 64, 64);
    tracker.beginFrame();
    tracker.beginFrame();
    try testing.expect((try tracker.see(testing.allocator, 1, .identity, 64, 64)).fresh);
    for (0..forget_after + 1) |_| tracker.beginFrame();
    try testing.expect(!tracker.knows(1));
}
