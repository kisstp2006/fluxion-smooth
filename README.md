# Fluxion Smooth

What makes every soft edge in a renderer smooth: the pieces that temporal antialiasing, soft shadows, volumetric fog and volumetric clouds share.

Each effect takes a few samples and spreads them well. What is left of their error is gathered over frames and blurred away, rather than shown as grain or bands. Part of [Fluxion](https://github.com/kisstp2006/fluxion-engine). It is built on [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) and [Fluxion Shader](https://github.com/kisstp2006/fluxion-shader), and runs on every backend they have (Vulkan, Direct3D 11 and 12, OpenGL, WebGL) with fragment passes only.

## Pieces

| | What it is |
| --- | --- |
| `jitter` | Where in its pixel each frame is drawn from: the Halton sequence in bases two and three, and a projection moved by it (`Jitter.apply`). |
| `noise` | Two kinds of noise, both moved on every frame. **Interleaved gradient noise** (Jimenez 2014) is a formula with no texture. **Blue noise** is a 64 × 64 texture made by void-and-cluster and moved on by the golden ratio, so that each pixel's values over time are spread evenly, as spatiotemporal blue noise's are. |
| `history` | What each view saw last frame (`Tracker`): last frame's view and projection, and whether what it gathered still holds. A gathering starts again for a new view, a new size or a cut. |
| `parts` | The shader side, in Fluxion Shader's language. See the list below. |
| `src/render/rhi.zig` | The GPU side: the blue noise as a texture, and each view's pictures kept from frame to frame (`Histories`), two of each, swapped every frame. A program builds it with its own RHI and Shader, so that a `Device` stays one type. |

The shader parts are:

- **Noise.**
- **Reprojection:** where a point was on last frame's screen.
- **History clipping:** YCoCg, variance clipping, and luminance weighting.
- **Catmull-Rom reading:** five bilinear reads, so a reprojected picture stays sharp.
- **Edge-aware filter weights:** by depth, by normal and by brightness, plus the à-trous kernel.
- **Upsampling:** an effect drawn at a lower size brought up by depth, nearest in depth at an edge.
- **An effect's own gathering** (`parts.gather`): a picture whose noise moves on each frame - the screen's occlusion, the light in the air - added to what it gathered, taken back along the motion and clipped to its neighbours.
- **Temporal antialiasing's resolve** (`parts.resolve`): this frame's jittered picture, its jitter filtered off, added to the history taken back along the motion of the nearest neighbour, clipped in YCoCg and weighted by brightness.

```zig
const smooth = @import("fluxion_smooth");

tracker.beginFrame();
const seen = try tracker.see(gpa, camera_key, view_projection, width, height);
const drawn = (smooth.Jitter{}).apply(projection, tracker.frame, width, height);
// seen.previous takes a point back to last frame; seen.fresh starts again.

const source = my_header ++ smooth.parts.all ++ smooth.parts.catmullRom("readHistory", "history") ++ my_body;
```

A part reads no block of its own. A part that reads a texture is made for the texture the program names, so the program keeps its slots. Every name in a part begins with `smooth`.

## Building

```bash
zig build test        # the tests, including every part compiled for every backend
zig build blue-noise  # src/blue_noise.bin made again
zig build docs
```

## License

BSD-2-Clause. See [LICENSE](LICENSE).
