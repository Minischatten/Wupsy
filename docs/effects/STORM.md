# Storm: visible native lightning (stage 1)

Original Swift/Metal implementation developed for Wupsy from the requested visual
requirements. No Blender/Geometry Nodes implementation, shader or asset is used.
No runtime dependencies or image resources are required.

## Format and coordinates

An additive WSS-v1 layer has required `type: "storm"` and `storm` configuration;
optional `visible` defaults to true, optional `name` uses WallpaperTitle rules.
All configuration fields below are required in JSON. Unknown fields, nulls,
invalid values and hidden invalid layers fail explicitly. Old projects retain
meaning; older readers reject the new type. No format migration.

| Configuration | Default | Valid bounds |
| --- | --- | --- |
| x, y | 960, 1000 | −1,000,000…1,000,000 logical canvas units |
| direction | 0 | [0,360) degrees; 0 down, 90 right |
| length | 800 | 1…8192 |
| spread | 120 | 0…2048 |
| width | 2 | 0.25…32 full core width |
| glow | 24 | 0…128 additional half-width |
| brightness | 1 | 0…8 |
| red, green, blue | 0.55, 0.7, 1 | 0…1 native RGB components |
| branchDepth | 2 | integer 0…3 |
| interval | 4 | 0.5…3600 seconds |
| duration | 0.12 | 0.01…0.5 seconds per pulse |
| flashes | 2 | integer 1…3 |
| flashGap | 0.1 | 0.02…0.5 seconds between pulses |
| seed | 1 | UInt32 |

All numeric values must be finite. Add in Editor adapts x/y/length/spread to canvas
size. Position is the main bolt's start, in lower-left-origin canvas coordinates.
Direction rotates the local downward bolt counterclockwise. Width, glow and speed
of events do not change with raster density or frame rate. No image transform or
composition field is accepted on a storm layer.

## Events and geometry

Fixed cadence, with a seed-derived onset at 10…20% of each interval. Domain-separated
64-bit integer mixing produces schedule phase and geometry samples. Geometry is
keyed by the interval cycle's Double bit pattern, seed and geometry parameters;
large finite times use bounded modulo arithmetic, never replay old events.
The same configuration and playback time reproduce the same event and bolt.

Presentation duration is max(0.05, duration), so short authored impulses remain
visible at 24 fps. Pulse intensity holds through 0.04 s and then decays; subsequent
pulses use factors 0.72 and 0.72². Full event span is flashes × presentationDuration
+ (flashes−1) × flashGap, and must be at most 75% of interval. No overlap within
one emitter. Zero intensity gaps keep the same event identity/geometry.

64 segments form the main line, using bounded midpoint offsets at decreasing scales. Each branch level creates two half-resolution
paths per parent: total segments = 64 × (branchDepth+1), at most 256 per layer.
The local path and immutable segment-instance buffer are cached per player
and layer until a different event/geometry key is drawn. Position, direction,
color, brightness and timing changes do not rebuild a matching event buffer.
No timers, simulation history or frame-dependent randomness. Paused time stays
frozen; player reconstruction can regenerate the same event from elapsed time.
New playback starts its deterministic sequence at zero. Displays currently use
independent clocks; precise inter-display phase synchronization is deferred.

## Rendering and budgets

One additive RGB draw per active layer renders the narrow pale core and analytical
soft glow with rounded analytical segment caps. Connected segments carry their
previous/next path points. The fragment shader assigns capsule overlap to the
nearest connected segment (previous wins ties, with a subpixel tolerance), so a
join emits once instead of adding two cores/glows. Separate branches and actual
crossings can still add light. The seeded path coordinates are unchanged.
Alpha is left unchanged. No blur pass, scene buffer, global illumination, mask or
image effect. Native BGRA8 UNorm clamps bright overlaps; this is not HDR.
Painter order determines foreground occlusion for both core and glow.

At most eight declared storm layers, including hidden layers. Scene segment ceiling
4096; with current depth/layer bounds the reachable maximum is 2048. At most eight
simultaneous events and at most two events/second/emitter (16/second/scene).
Glow extent is bounded by its parameter; geometry needs no texture allocation.

One packed segment instance is 48 bytes; the vertex shader generates its six quad
vertices. Each cached event uses at most 12 KiB; eight caches use at most 96 KiB. Two in-flight player frames may retain replaced event buffers until
GPU completion (conservative 288 KiB for cache plus two full sets, excluding Metal
allocation overhead). Commands explicitly retain immutable buffers. Preview
replacements can temporarily retain separate old/new player resources.

## Editor and persistence

Add/select/reorder/rename/hide/delete uses native layer identities and document
mutations. Numeric controls use the exact Double path (including UInt32 seeds),
finite validation and one Undo per accepted edit. Rename is applied with Return
or the Rename button. Event/cache/player state is not serialized. No assets are
added to save catalogs. Save, Save As and preview stale-work rules remain unchanged.
Storm-only value updates can reuse prepared resources and the player; geometry
cache keys isolate actual geometry changes. Static Edit Canvas omits animated
Storm pixels, like Rain and Trail; Live Preview and desktop use the native layer
loop. Selecting a visible Storm layer shows a session-only region using the shared
image handles, hit-testing, gesture math, cancellation and Undo transaction.

For branch depth d, frame height is length × (1+0.25d), width is
4×(spread+1)+0.4d×length. Its top midpoint is the existing start position, its
orientation the existing direction. This is a fixed authoring region with branch
allowance, not a per-event silhouette or clipping rectangle. Random branches/glow
may extend outside it. It never depends on time or seed. Corners scale about the
opposite corner; Shift allows independent axes. Height maps back to length; width
maps back to spread after subtracting the branch allowance. Spread is clamped at
zero; invalid length/position/range changes retain the last valid gesture value.
Rotation uses the shared frame center and can therefore move the start position,
just as rotating an offset rectangle would. No transform fields are serialized.
Unchanged numeric parameters retain their Double precision.

The inspector uses the existing native ColorPicker, Trail color adapter and 400-ms
coalescing pattern. Linear RGB components remain the existing red/green/blue JSON
fields; opening the picker does not rewrite them. Accepted picker edits update RGB
atomically; Save, selection change, Undo or panel disappearance finishes the
transaction. Global illumination and arbitrary event jitter remain deferred.

Synthetic example: [WSS-Storm-v1](../../Test-Wallpaper/WSS-Storm-v1/README.md).
