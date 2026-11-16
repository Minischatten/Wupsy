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

## Optional procedural Milky Way (stage 3)

`starfield.milkyWay` is an optional additive WSS-v1 object. When absent, all defaults
below apply; the object is omitted by canonical encoding only at complete defaults.
All listed fields are required inside an explicit object. Unknown/null/non-finite
or out-of-range values fail even on hidden/disabled layers. No version bump or
migration. Older strict readers reject the newly configured field explicitly.

| Field | Default | Bounds / meaning |
|---|---|---|
| enabled | false | boolean |
| positionX, positionY | 0.5, 0.5 | 0…1, normalized center within the Starfield rectangle |
| angle | 30 | 0…360°, counterclockwise; 0 horizontal, 90 vertical |
| width | 0.22 | 0.03…1, band width as a fraction of the shorter region side |
| intensity | 0.45 | 0…2 emission multiplier |
| structure | 0.75 | 0…1 cloud/grain contrast and density modulation |
| dust | 0.7 | 0…1 suppression of the band's own light in dark lanes |
| red, green, blue | 0.8, 0.86, 1 | 0…1, own freely editable native linear RGB |
| seed | 1 | UInt32; independent of Starfield and meteor seeds |

Original bounded Swift/Metal implementation, with no external shader, texture or
runtime dependency. This is a stylized galactic field, not an astronomical model.
A separate optional immutable pipeline is prepared lazily on effective activation,
then shared by compatible snapshots; it can remain held until the resource family
is released. Off/zero-intensity/black/hidden draws nothing. Old projects do not
compile this pipeline. Other native pipelines and color processing are unchanged.

One four-vertex region quad renders BEFORE stars and meteors at the Starfield
layer's painter-order position. Additive RGB leaves destination alpha unchanged;
later source-over foregrounds occlude the whole field. The existing Storm final
illumination pass includes it naturally. The region quad bounds soft edges too.
No new image, render target, simulation buffer, cached structure texture or GPU
geometry buffer. Inline uniforms use 96 bytes plus a four-byte seed per draw.
GPU commands keep immutable resources alive through existing completion ownership.

The fragment shader combines a metric rotated variable-width Gaussian envelope
with four bounded periodic images and bilinear partition weights. Six fixed seeded
periodic noise evaluations drive broad occupation, local stellar clouds, fine/micro
detail and two independent dust domains. Nonlinear occupation and sparse bright
condensations replace the previous nearly constant diffuse floor. Diffuse light is
weak; two independently hashed finite-cell star fields follow local cloud density,
without extending the ordinary Starfield instance population. Cell-edge coverage
falls smoothly to zero to avoid discontinuities during subpixel drift.

Dust is variable-width and patchy, with domain-warped displacement instead of a
sinusoidal hairline. Weighted exponential transmittance attenuates BOTH diffuse
light and fine stellar emission. No black overlay is drawn; ordinary Starfield
stars remain unaffected. The own base tint varies by at most ±5% per channel.
Structure/color/intensity/dust changes remain uniforms, not CPU generation.
The optical revision changes appearance at unchanged parameters but does not
change JSON fields/defaults, seeds, geometry, event scheduling or other renderers.
The band stays stylistic, not an astrophysical simulation or sky survey.

The same X/Y drift phases as stars translate the complete periodic field. Double
phase reduction precedes Float uniforms. No independent timer, evolution or
flickering. Four periodic images and periodic noise eliminate seam jumps/empty
wrap strips at every angle. Periodic continuation can show band fragments at
opposite edges, including when stationary; normalized centers 0 and 1 coincide.
A complete travel cycle repeats. Rotations use scene distances to preserve aspect.

An effective Milky Way alone is static. With drift it animates even at ordinary
star count/brightness zero or black Starfield color. Own black RGB disables it;
shooting-star motion and their event stream remain independent. At most the existing
eight Starfield layers draw one extra quad each; no new unbounded resource pool.
Pixel shading cost scales with covered output pixels and active layer count. In an
otherwise animated scene the bounded shader is evaluated each frame rather than
keeping a 4K texture. With no animation the existing on-demand player draws only
when needed. Quality/output resolution scales the fragment workload normally.

The inspector uses numeric position/angle/width/intensity/structure/dust/seed fields
and a native independent ColorPicker. Both color roles share the existing coalesced
Undo boundary while keeping distinct RGB fields; switching roles ends the previous
transaction. Numeric commits retain the crash-safe interaction-only completion.
No additional Canvas handles. The static canvas remains images plus region frame.

Synthetic black/sky/transparent-foreground acceptance project:
[WSS-Starfield-Milky-Way-v1](../../Test-Wallpaper/WSS-Starfield-Milky-Way-v1/README.md).

### Reproducible visual comparison

`WSSMilkyWayPreviousReference` freezes the original Wupsy shader in the test target
only. The app contains no legacy-mode switch. `WSSMilkyWayVisualComparisonTests`
renders the same synthetic foreground/stars, Milky Way seed 1, star seed 42 and
all other identical parameters at intensities 0.45 and 0.12, output 960×540. Set
`WUPSY_MILKY_COMPARISON` to an existing output directory to export before/after PNGs
without subsequent image processing. PNGs and review HTML belong in ignored dist
or temporary storage, not project assets. A patch-contrast regression checks
stronger local variation and reduced diffuse mean along the visible main band.

The comparison warms equal 3840×2160 targets and reports the median of three
alternating full-frame GPU samples for each variant. The old reference is drawn
in a separate encoder before the unchanged ordinary composition, whereas the new
field uses its normal in-composition encoder; this is a local practical comparison,
not an isolated universal shader benchmark. No timing assertion is enforced.
