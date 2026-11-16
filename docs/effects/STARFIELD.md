# Starfield: native seeded stars and optional shooting stars

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

Without effective twinkle, drift or shooting stars this layer does not mark the
scene animated; other layers may still animate the scene. Zero star count/brightness
suppresses background stars; black base RGB also suppresses shooting stars.
The static editing canvas retains its image-only behavior, with a movable,
scalable frame from a session-only adapter. Rotation is neither shown nor accepted.
Gestures and coalesced native color edits follow existing Undo/Save boundaries.

## Optional shooting stars (stage 2)

The optional `starfield.shootingStars` object adds the following required fields.
Absent means the complete defaults below; canonical encoding omits the object only
when all its settings equal those defaults. Unknown fields, nulls and invalid values
fail even on disabled/hidden layers. Existing manifests keep their original star
population, appearance and static behavior. WSS version remains 1; older strict
readers reject the newly configured object explicitly.

| Field | Default | Bounds / meaning |
|---|---|---|
| enabled | false | boolean |
| frequency | 2 | 0…12 events per minute on average; zero disables |
| speed | 700 | 50…3000 logical units/s, varied by 0.85…1.15 per event |
| tailLength | 180 | 0…1024 logical units; zero keeps only the head |
| brightness | 1.5 | 0…4 emission multiplier; zero disables |
| direction | 315 | 0…360 degrees; 0 right, 90 up, 270 down |
| directionVariation | 12 | 0…90 degrees, symmetric deviation from direction |

### Inspector units and direction controls

The inspector shows **shooting stars per 10 minutes** in 0…120, including fractional
values. Display = stored frequency ×10; committing divides by ten. Thus 1 means an
average of one event per ten minutes, 2 per five minutes, 5 per two minutes and 10
per minute. Zero disables events. The default remains 2/minute, displayed as 20.
Persistence, validation limits and the scheduler keep their original per-minute
units; old files are not migrated or rescaled. Untouched values retain their exact
saved precision. A UI-confirmed unchanged display value also avoids a ×10/÷10
roundtrip. The deterministic irregular intervals and population are unaffected.

Eight SF Symbol arrow buttons map right/up-right/up/up-left/left/down-left/down/
down-right to 0/45/90/135/180/225/270/315°. The numeric 0…360° field remains available.
Both use the same document angle and Undo transaction path; no separate selection
is persisted. Arrow buttons first validate/finish any numeric draft so it cannot
overwrite the preset later; invalid drafts retain focus and block the selection. The center arrow always displays the actual angle, including precise
intermediate angles. Only an exact preset angle highlights its button; stored 360°
selects the right arrow without being rewritten to zero on open. Color, rate,
direction and drift have separate local help texts.

Meteors inherit the unvaried Starfield base RGB; they do not depend on star count,
star brightness, color variation or drift. A meteor-only layer with count zero can
animate. Black RGB suppresses the whole layer. A shared seed intentionally gives
the same event sequence; choose different seeds for independent layer sequences.

Each period of 60/frequency seconds owns one seeded event at 10…90% of its period.
The METEOR random domain uses only layer seed and slot, separate from STAR draws.
Jitter yields nonconstant adjacent intervals (20…180% of the mean). Stateless lookup
checks only the current and preceding slots, irrespective of seek distance. No
backlog, timer or event history. The bounded slot cycle has 2^32 slots: even at
12/minute it repeats only after more than 680 years. Double modulo precedes slot
conversion and age uniforms; enormous finite seeks remain bounded and reproducible.
Negative/non-finite times yield no events. The existing playback clock handles pause.

Events last 1.1…2 seconds with a smooth 15% entrance and 30% exit envelope. Starts
are seeded inside the region. Head position is analytical start + velocity × age;
head radius and brightness vary modestly by seed. The tail trails against heading
with finite soft radial coverage and a longitudinal fade, independent of star drift.
Head and tail are both clipped to the same rectangle and use the same painter-order
occlusion as stars. Exiting the rectangle does not wrap the meteor.

A second immutable pipeline in the existing Starfield renderer reuses its Metal
library and additive RGB/unchanged-alpha blend setup. Each active event adds one
four-vertex quad and 80 bytes of inline uniforms. There are at most two active
events per layer and sixteen across eight layers; no new GPU buffers, textures,
simulation/history targets or per-frame MTL resource allocation. The star pipeline
and population buffer are shared unchanged for all shooting-star parameter edits.
GPU commands retain resources through completion using the existing player contract.

The inspector uses the crash-safe parameter transaction boundary from stage 1:
finish gestures/coalesced Undo without recursively resigning the committing field.
Numeric edits, toggle, Undo/Redo, Save/Reopen and Preview reuse follow existing rules.
The editing canvas continues to show images and the position frame only.

Synthetic shooting-star scene:
[WSS-Starfield-Shooting-Stars-v1](../../Test-Wallpaper/WSS-Starfield-Shooting-Stars-v1/README.md).

Synthetic acceptance scene: [WSS-Starfield-v1](../../Test-Wallpaper/WSS-Starfield-v1/README.md).
