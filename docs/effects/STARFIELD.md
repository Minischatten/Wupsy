# Starfield: native seeded stars (stage 1)

Original Swift/Metal implementation for Wupsy; no downloaded shaders, textures,
assets or runtime dependencies. The seeded population uses the existing native
SplitMix64 implementation with a separate STAR stream (see RAIN-RANDOM.md).

## Model and compatibility

A WSS-v1 layer has type `starfield`, required `starfield` configuration, optional
`name` and `visible` (true). Unknown fields, nulls and invalid values fail even on
hidden layers. Older readers reject the new type. No format migration/version bump.
All configuration fields below are required; constructor/editor defaults follow.

| Field | Default | Bounds / meaning |
|---|---|---|
| x, y | 0, 0 | −1,000,000…1,000,000; lower-left logical scene origin |
| width, height | 1920, 1080 | 1…8192 each; area ≤32 Mi logical square units |
| count | 1500 | integer 0…16384; independent of output resolution |
| size | 1 | 0.25…16 logical units, core scale |
| brightness | 0.8 | 0…4 emission multiplier |
| red, green, blue | 1, 1, 1 | 0…1 linear RGB, existing native color adapter |
| colorVariation | 0.15 | 0…1; at most ±15% per channel, clamped 0…1 |
| seed | 1 | UInt32 |
| twinkleEnabled | false | boolean |
| twinkleIntensity | 0.3 | 0…1 modulation depth |
| twinkleSpeed | 0.3 | 0…2 Hz base rate; eight independent rate groups |
| driftX, driftY | 0, 0 | −10…10 logical units/s; positive X right, positive Y up |

Add fills the canvas rectangle. Count remains fixed on resize, and star size is
independent of region size. Normalized seed positions and size/light/phase/color
variations use a fixed eight-draw sequence per star; changing count preserves its
prefix. Only count/seed require a new population. Other compatible edits share the
immutable pipeline and buffer. No stochastic state advances per frame.

## Rendering and lifetime

Instanced four-vertex quads draw directly at the layer's painter-order position,
with additive RGB and unchanged destination alpha. Later source-over images
occlude them. Analytic cores and finite soft halos require no image or full-scene
scratch texture. Existing composition/color processing stays unchanged; optional
Storm illumination still affects the completed scene.

Instance data is 32 bytes per star: ≤512 KiB per layer, ≤2 MiB per scene. At most
eight declared layers and 65536 total stars, including hidden ones. CPU population
arrays are temporary during preparation; prepared resources retain GPU buffers.
Commands retain resource snapshots until GPU completion, as in the native player.
Removing/replacing scenes releases their ownership; compatible snapshots can share.
Shader/driver and existing drawable costs are additional, not predicted by these
buffer figures. A dedicated `bufferBytes` property exposes Starfield geometry cost.

Twinkling uses independent seeded phases/rate groups; shared playback time controls
pause/resume. Double periodic reduction precedes Float uniforms for drift and each
rate group. No timers or CPU particle updates. Drift wraps on the region torus;
nine bounded tile instances per star cover halo crossings. Off-region tile quads
are degenerate; fragment clipping bounds all light. Halo extent is capped to 49%
of the smaller region dimension to preserve this contract in very small regions.
Periodicity remains perceptible if observed for a complete travel cycle.

Without effective twinkle or drift this layer does not mark the scene animated;
other layers may still animate the scene. Zero count/brightness/black are neutral.
The static editing canvas retains its image-only behavior, with a movable,
scalable frame from a session-only adapter. Rotation is neither shown nor accepted.
Gestures and coalesced native color edits follow existing Undo/Save boundaries.

Shooting stars are deferred. A later optional configuration/event renderer can
share region, playback time and layer order without a framebuffer history texture;
no reserved JSON fields or incomplete shooting-star behavior are present now.

Synthetic acceptance scene: [WSS-Starfield-v1](../../Test-Wallpaper/WSS-Starfield-v1/README.md).
