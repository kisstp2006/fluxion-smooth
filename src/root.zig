// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Smooth - what makes every soft edge in a renderer smooth: the
//! pieces temporal antialiasing, soft shadows, volumetric fog and clouds
//! share, so that each effect takes few samples, spreads them well, and has
//! what is left of their error gathered over frames and blurred away rather
//! than shown as grain or bands. See README.md.
//!
//! - `jitter`: where in its pixel each frame is drawn from.
//! - `noise`: interleaved gradient noise and blue noise, moved on each frame.
//! - `history`: what each view saw last frame, and when what it gathered
//!   no longer holds.
//! - `parts`: the shader side - noise, reprojection, history clipping,
//!   Catmull-Rom reading, edge-aware filter weights, upsampling.
//!
//! The GPU side - the blue noise texture and each view's pictures kept from
//! frame to frame - is `src/render/rhi.zig`, which a program builds with its
//! own Fluxion RHI and Shader, as it does Fluxion Debugdraw's.

pub const jitter = @import("jitter.zig");
pub const noise = @import("noise.zig");
pub const history = @import("history.zig");
pub const parts = @import("parts.zig");

pub const Jitter = jitter.Jitter;
pub const Tracker = history.Tracker;

test {
    _ = jitter;
    _ = noise;
    _ = history;
    _ = parts;
}
