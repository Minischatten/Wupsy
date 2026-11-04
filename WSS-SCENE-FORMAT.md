# Native WSS scene format, version 1

Supported image effect types are `flow`, `ripple` and `clouds`; native `rain` and
`cursorTrail` layers remain supported. Unknown effect types, including the removed
`surfaceAdvection` and `waterSurface`, fail explicitly, even on hidden layers or
inside effect chains. No legacy normalization, migration or fallback is performed.
This boundary also applies to native projects in backup/restore/recovery payloads.

A native scene is an ordinary directory with `scene.wss.json` at its root and
wallpaper-owned PNG assets. It is independent of Wallpaper Engine and its shaders,
materials, texture containers and runtime resources. It is not an archive format.
Import either the directory or that exact entry file. The entry's `format` must be
`wss-scene` and its integer `version` must be `1`. A directory containing this entry
is treated as native even if other project metadata exists; malformed native input
never falls back to another parser.

```
wallpaper/
  scene.wss.json
  assets/
    background.png
    mask.png
```

## Minimal document

```json
{
  "format": "wss-scene",
  "version": 1,
  "title": "Example",
  "canvas": { "width": 1920, "height": 1080 },
  "layers": [
    {
      "image": "assets/background.png",
      "transform": { "center": [960, 540], "size": [1920, 1080] },
      "composition": "replace"
    }
  ]
}
```

`WSSSceneDocumentV1` is a file DTO and maps into `WSSScene`; internal renderer types
are not the serialization contract. All unknown fields are rejected, including
metadata fields. Unknown versions/effects are errors. No migrations or speculative
forward-compatible interpretation are performed. Null is rejected for all fields except mask, where absence and null both mean no mask. This is enforced by the shared decoder field validator before decodeIfPresent defaults can apply.

## Canvas and layers

Canvas dimensions are positive integers, at most 8192 per axis and 32 Mi pixels
in total. `title` is required, nonblank and at most 1024 UTF-8 bytes. Optional
`background` is an RGB array in 0…1, default `[0,0,0]`.

There are 1…128 ordered image, Rain or CursorTrail layers, drawn from first to last. Each image layer has:

- `name`: optional user-facing image-layer name (same single-line, non-empty,
  at-most-256-character rules as wallpaper titles). Display metadata only; it is
  independent of asset paths and stable editor layer identity. Absent names retain
  the existing editor asset-label fallback; existing projects are not migrated.
- `image`: required relative PNG path or explicit image descriptor (see asset boundary).
- `transform.center`: required `[x,y]` in logical canvas units. Origin is at the
  lower left, positive x right, positive y up. The image quad is centered here.
- `transform.size`: required positive `[width,height]`, each at most 8192.
- `transform.scale`: optional positive `[x,y]`, default `[1,1]`, at most 100.
- `transform.rotation`: optional radians, default 0, positive counterclockwise.
- `opacity`: optional 0…1, default 1.
- `visible`: optional boolean, default true.
- `composition`: optional `sourceOver` (default) or `replace`. These retain the
  renderer's existing premultiplied-alpha/source-over and replacement contracts.
- `effects`: optional array, default empty; ordered Flow/Ripple/Clouds stages, including mixtures and repeats, subject to the effect budgets below.

All numbers must be finite. Center/rotation magnitudes and resulting transform
components are limited to 1,000,000. PNG origin/UV is top-left; the existing image
vertex mapping relates it to canvas coordinates. Raster density does not change
logical geometry or animation speed.

## Clouds and mask

A layer's optional `effects` can contain:

```json
[
  {
    "type": "clouds",
    "velocity": [12, -3],
    "scale": 600,
    "intensity": 0.3,
    "density": 0.5,
    "seed": 7,
    "mask": "assets/mask.png"
  }
]
```

The base fields `velocity` and `scale`, plus `intensity`, `density` and `seed`,
remain required for the velocity/scale spelling. They map directly to native values without
an import adapter. Alternatively replace BOTH base fields with `primaryField`:

```json
{
  "type": "clouds",
  "primaryField": {"velocity": [18, -2], "scale": 1600},
  "secondaryField": {"velocity": [-12, 8], "scale": 700},
  "secondaryInfluence": 0.4,
  "intensity": 0.65,
  "density": 0.55,
  "brightness": 1,
  "shadingAmount": 0.6,
  "shadingDirection": 45,
  "seed": 17,
  "mask": "assets/mask.png"
}
```

Specifying `primaryField` together with top-level velocity/scale is an error. Each
field requires exactly velocity and scale. Velocity components are finite
-4096…4096 local image logical units/second (positive x right, positive y down).
Scale is finite 1…8192 logical units per repeated tile: larger means larger clouds;
primary lattice spacing is scale/8 before finer detail. Both are independent of
Standard/HiDPI density. Intensity/density remain 0…1 and seed UInt32.

New optional fields have only native defaults: secondaryField absent (disabled),
secondaryInfluence 0.35 (range 0…1), softness 0 (0…1), brightness 1 (0…2), shadingAmount 0 (0…1),
shadingDirection 0° ([0,360)). Influence zero disables secondary. Direction is local
image 0 up, 90 right, 180 down, 270 left. Shading zero is neutral. Brightness is tone
gain with SDR clamping, not opacity; zero produces black clouds, one preserves old
unshaded white, two can brighten shaded tones without exceeding white. Alpha and
coverage remain unchanged by tone. All values must be finite. Null (except the
optional mask), unknown fields and incomplete nested fields are rejected. Old JSON selects the exact original v1
pipeline; no format version bump, engine defaults or fingerprints are involved.
See `WSS-EFFECTS.md` for the own field combination, shading formula and sample costs.

`softness` is optional, finite 0…1. Zero preserves the exact existing structured
v1/v2 look and shader paths; one creates broader diffuse transitions with less
fine fragmentation. It changes native structure, not size, opacity or brightness.
Larger `scale` remains the independent size control. Density endpoints, masking,
independent field motion and alpha remain intact. Unknown fields/null/invalid
ranges remain errors. This is an additive v1 extension with no engine default.
See the own formula and editor-oriented semantics in `WSS-EFFECTS.md` and the
fully procedural `Test-Wallpaper/WSS-Clouds-Storm/` example.

A Clouds/Ripple mask may also use the same explicit asset object as an image:
`asset`, `encoding`, `width`, `height`, `uvScale`, `filter`, `edge`, `mipmapped`.
This v1 spelling preserves explicit padded source UVs;
string PNG references retain their existing behavior. Mask contracts require
`filter: "linear"`, `edge: "clamp"`, `mipmapped: false`; image encoding/dimension/path
validation also applies. Conflicting contracts for one asset are rejected. Older
readers reject the object spelling rather than silently losing its UV scale.

A mask uses linear red intensity, normalized local image UV and clamped edges;
zero leaves the base image unchanged and one applies the full configured effect.
There is no separate mask transform. Channel decoding does not use the color-image
premultiplication/conversion path. Unsupported layouts, including nonopaque
premultiplied mask data, are rejected.

## Asset and resource boundary

String image references support files ending in `.png` with a PNG signature, a single image and supported 8-bit decoded pixels. Assets are at most 8192 per axis and 32 Mi pixels.
Existing WSS decoded-image and mask budgets remain enforced. All referenced assets, including hidden layers, must be readable during preparation/import.

Explicit image descriptors contain exactly asset, encoding, width, height, uvScale, filter, edge and mipmapped. encoding image accepts a single PNG/JPEG payload whose decoded dimensions equal the declared dimensions; encoding rgba8 requires exactly width×height×4 straight RGBA bytes. Dimensions are 1…8192 with at most 32 Mi pixels; uvScale contains two finite components in (0,1]. filter is linear or nearest; edge is clamp or repeat; mipmapped is boolean. The same asset cannot have conflicting descriptors. These are native data contracts, not external texture containers. Mask descriptors additionally require linear/clamp/non-mipmapped sampling and valid scalar data.

Example explicit image value:

```json
{"asset":"assets/background.png","encoding":"image","width":1920,"height":1080,"uvScale":[1,1],"filter":"linear","edge":"clamp","mipmapped":false}
```

Paths are nonempty, relative, slash-separated components. Empty components, `.`
and `..`, backslashes, NUL, colons, absolute paths and tilde paths are rejected.
Root/asset paths may not traverse symlinks. Managed import also rejects symlinks
and special files throughout the complete source directory. Files and scene JSON
have bounded reads. Asset errors identify WSS data, never an engine shader.

## Library and playback

Native entries use `kind: scene` and `sceneSource: nativeWSS`, with no scenePlaybackMode. Missing/obsolete source metadata and playback modes are rejected, never interpreted as legacy imports. Reading does not migrate data.

The managed store validates the source through actual native WSS preparation,
copies the complete directory into a staging area, validates the copy, then claims
a collision-safe `Wallpapers/WSS/<name>` directory atomically. Persisted paths are
relative. Import rollback/removal use the existing managed ownership safeguards.
The original source is not needed after import.

Playback is native document → validated WSSScene → native PNG assets → existing
WSS resources → WSS player. Static/animated rendering, timing, pause/resume and
resolution policy remain those of the existing WSS renderer. No external parser, resource provider or shader fingerprint participates in this path.

## Native Rain layers (additive v1 extension)

`layers` is now an ordered sequence of image and Rain nodes. Existing image entries
without `type` retain exactly their former meaning; `type: "image"` is also accepted.
An explicit `type: "rain"` has `region`, `rain`, optional `visible` (true),
optional `composition` (`sourceOver`) and optional `mask`. Unknown layer types/fields
remain errors.
Older readers reject Rain instead of silently omitting it. No document migration.

```json
{
  "type": "rain",
  "region": { "x": 0, "y": 0, "width": 1920, "height": 1080 },
  "composition": "sourceOver",
  "rain": {
    "direction": 0, "speed": 900, "density": 100,
    "length": 32, "width": 1.2,
    "opacity": { "min": 0.08, "max": 0.24 }, "seed": 1
  }
}
```

All seven Rain settings and all four region fields are required. Float values must
be finite. Direction is `[0,360)` degrees (out-of-range values are rejected, not
wrapped); 0 down, 90 right, 180 up, 270 left in logical canvas coordinates.
`velocity = speed * (sin(angle), -cos(angle))`. Speed is 0…6000 logical units/s;
density 0…2000 drops per million logical square units; length 0.5…256 and **full**
width 0.25…8 logical units before internal depth scaling (length also has independent native
0.5/1/1.5 class variation). Opacity min/max are 0…1,
min ≤ max. Seed is UInt32. No color parameter; streaks are neutral white.

`rain.profiles` is optional. When present, it contains exactly three objects with
required finite `length` (0.25…384) and `width` (0.25…8), in logical units before
depth scaling. Length and width are selected together, deterministically, from one
profile per instance. The seven base settings remain required; profile geometry
replaces their length/width variation. Without profiles the original population,
length classes and rendering remain unchanged. Open/display/save do not add profiles.
This is an additive v1 extension; older strict readers reject unknown fields.

The optional layer-level `mask` uses the existing native image descriptor (asset,
`encoding`, `width`, `height`, `uvScale`, `filter`, `edge`, `mipmapped`).
It is scalar coverage: absent means full effect
inside the region; black suppresses Rain and white preserves it. Mask UV spans the
entire region with texture top at region top, independent of layer order. Mask assets
participate in the normal referenced-resource, save and validation paths.

Region is an axis-aligned rectangle in lower-left canvas coordinates. Origin
magnitudes are bounded by 1,000,000; positive dimensions are at most 8192 per axis
and 32 Mi logical square units. Regions may extend beyond the canvas: generation
and density use the entire region, fragment clipping uses its rectangle, and the
normal canvas projection crops the output. No implicit repositioning or clamping.

Nominal count is `round(density * region.width * region.height / 1_000_000)`.
Padded, direction-aligned domain instances are counted separately; the hard combined
budget is 8192 across all Rain layers, including hidden ones and margins. Exceeding
it is an error. A nominal count of zero generates no instances. Backing resolution,
Standard/HiDPI and drawable resize never change these logical counts or seeds.

Rain supports native `sourceOver` (default) and `additive`. Streak output is
premultiplied neutral RGB/alpha. Source-over uses `S.rgb + D.rgb*(1-S.a)`;
additive uses `S.rgb + D.rgb`. Both use `S.a + D.a*(1-S.a)` for output alpha;
UNorm output clamps at its storage range. No engine photometry equivalence.
Rain has no image/effects fields; only an explicit mask adds an asset dependency.
Array position determines occlusion: place Rain between a background and foreground
image, or after both for foreground Rain. Multiple Rain layers use the same ordering.
See `WSS-EFFECTS.md` for preparation, time, depth and analytic-streak details.


## Ripple v1

An image layer may contain a native Ripple stage:

```json
[{"type":"ripple", "amplitude":12, "wavelength":180, "stretch":1.6,
  "direction":180, "travelSpeed":35, "evolutionRate":0.35, "seed":7319,
  "mask":"assets/mask.png"}]
```

All numeric fields shown are required. `mask` is optional; absent/null means full
coverage. It uses the same safe relative PNG paths and linear-red mask decoding
as Clouds. Unknown fields, missing files, symlinks and nonfinite/out-of-range
numbers fail. Mixed and repeated Flow/Ripple/Clouds stages are supported within budgets. Older strict readers may reject capabilities they do not recognize.

Parameter units, bounds, direction and time behavior are specified in
[the Ripple reference](WSS-EFFECTS.md#ripple). `amplitude`, `wavelength` and
`travelSpeed` use unscaled local image units; raster density never changes them.


## Flow and ordered stacks

A Flow stage requires a flowMap descriptor. speed defaults to 40, strength to 12, edgeProtectionPixels to zero, and edgeProtectionMode to imageBounds. region mode requires a flowRegion descriptor; imageBounds forbids it. Field formats are wss-flow-rgba8 (PNG) and wss-vector-field-f16 (.wssvf), both version 1. Regions use wss-flow-region-r8 (.wssregion), version 1. See [Flow](WSS-EFFECTS.md#flow) for exact byte formats, bounds and edge formulas.

```json
{"type":"flow","flowMap":{"format":"wss-vector-field-f16","version":1,"asset":"assets/field.wssvf"},"speed":40,"strength":12}
```

The effects array is an ordered sequence: each active stage reads its predecessor's completed image. Repetition and all mixtures of flow, ripple and clouds are allowed, up to 32 stages per image, 8 internal passes per stage, 64 passes per image and 256 passes per scene. All current effects cost one pass. Hidden and identity-elided stages still validate and count. Rain and CursorTrail remain separate scene layers, not entries in effects. Unsupported types fail explicitly.

Ripple additionally accepts structureRotation ([0,360), absent defaults to 0) and lateralDetail (0.125…8, absent defaults to 1). These change spatial structure/transverse detail, not the stored seed, nominal amplitude or format version. See [Ripple](WSS-EFFECTS.md#ripple).

## Non-destructive native editing

The editor works on a typed native document and independently owned immutable asset generations. Import copies source content; editing the managed copy never rewrites the external original. Missing/invalid project data is an error, never permission to regenerate it. Runtime history and editor session state are not serialized. See [editor workflows](docs/EDITOR.md) and [architecture](docs/ARCHITECTURE.md).

## Native cursorTrail layer

Version 1 additionally accepts a general procedural cursor trail at its serialized
position in painter order:

```json
{
  "type": "cursorTrail",
  "visible": true,
  "trail": {
    "colors": [{"r": 0, "g": 0.7, "b": 1}, {"r": 1, "g": 0.25, "b": 0}],
    "colorMode": "sampleRandom",
    "width": 12,
    "curveSmoothing": 0.15,
    "lifetime": 1,
    "emissionRate": 32,
    "fadeIn": 0.1,
    "fadeOut": 0.9,
    "opacity": 1,
    "edgeSoftness": 0.65,
    "seed": 1
  }
}
```

`visible` defaults true when absent. Trail parameters are required except optional
`maxLength` and `curveSmoothing`; unknown fields and explicit null values are rejected, including
unknown color components. Colors are 1–16 linear RGB
stops in 0…1. `sampleRandom` samples the palette using a deterministic seeded
scalar per point; `ageGradient` samples at age/lifetime. Linear RGB interpolation,
no hidden tint or engine color algorithm. Full width is in logical canvas pixels
(0 < width ≤ 256). Lifetime is seconds (0 < lifetime ≤ 10), emissionRate 1…512/s.
fadeIn/fadeOut are nonnegative seconds with sum ≤ lifetime. Opacity/edgeSoftness
are 0…1. All numerical values must be finite. Total lifetime×emissionRate across
all trail layers is limited to 4096; existing 128-layer scene budget also applies.

`curveSmoothing` is a finite Float in 0...0.5, defaulting to 0.15 when absent.
The editor calls it Kurvenauslenkung / Curve amount and offers a reset to 0.15.
It controls Bezier handle reach, not lifetime, alpha or edgeSoftness; five
subdivisions remain fixed. Zero keeps the centerline on each chord, larger amounts
may overshoot. Opening an older file does not write it; saving encodes the value.
Older strict readers may reject new saves containing this field. See
[the mathematical contract](docs/CURSOR-TRAIL-CURVES.md).

`maxLength`, when present, is a finite Float >0 and ≤16384 in logical canvas
pixels. Missing means unlimited; null is rejected. Encoding omits nil. Length
clips the sample polygon from newest backwards with an interpolated endpoint
(position, birth and palette coordinate), independently of lifetime. Existing
files remain unlimited without materializing this field. Older
strict readers reject documents containing the new field.

Trails emit at active-time intervals, interpolate between supplied pointer
observations, preserve old positions and expire by age. Coincident neighborhoods
produce no visible band. The player owns simulation separately from immutable
prepared resources. Pointer loss, backwards time, gaps longer than lifetime and
player stop/restart clear state. Cover projection uses the same centered crop as
images, independent of drawable backing scale. Per-layer additive RGB, destination
alpha preserved; analytic transverse coverage, no texture/runtime engine assets.
No properties of completed image/rain scenes change when no trail is present.

New editor-authored trails use two-color `ageGradient` and expose colors, spatial length, lifetime, full width and curve amount. Lifetime edits scale
both fades proportionally. Other palettes/modes are preserved until an explicit,
undoable conversion using the first and last palette stops. Save uses the normal
scene document; cursor position and runtime history are never persisted.

## Semantic codec and internal manifest save

The typed v1 document is the persistence source; runtime scenes are derived from it.
Canonical encoding may normalize key order, whitespace, omitted defaults, Clouds
primary-field spelling and absent/null masks. Transform values, ordered nodes,
resource paths, explicit asset contracts, sampling and seeds retain their meaning.
Unknown fields and unsupported versions remain errors; the 2-MiB manifest limit
applies to encoded candidates too. No editor state is added to the format.

The editor supports native Ripple, Clouds and Flow controls, Rain/profile and Trail authoring, as described in [the editor guide](docs/EDITOR.md).
Save never activates a different wallpaper. If its UUID is already active, the
running desktop refreshes to the committed snapshot; playlist state is preserved.
Image Add/Replace is limited to PNG/JPEG normalization and immutable generations.
Save validates the exact encoded bytes and all referenced assets through native
preparation, checks the loaded manifest/asset fingerprints, and publishes the
`scene.wss.json` manifest last with an atomic replacement. Existing assets remain untouched.
See [architecture](docs/ARCHITECTURE.md) for the save lifecycle and failure contract.

The editor workspace also permits visibility, image opacity/numeric transforms,
layer reorder and layer deletion (at least one layer remains). These use existing
v1 fields only. Session layer/effect IDs, selection, edit targets, split positions
and canvas navigation are never serialized. Resource inspection is read-only;
manifest saves may change the referenced subset of known project assets without
deleting assets. New images use exclusively installed immutable generation paths. Session undo retains access to unchanged old assets.
The static Edit Canvas composites image layers without effects, Rain or Trail;
this working representation does not redefine native playback/effect semantics.
The separate Live Preview shows the full working wallpaper.

Direct Canvas move/scale/rotation edits only the existing image transform fields.
Gesture state and handles are session-local; size and scale retain their existing
separate meaning, with positive scales and no new persisted fields.


Image Add/Replace does not change WSS version 1. Normalized eight-bit RGBA sRGB PNGs
use existing explicit `encoding: "image"` contracts, full UV and app-controlled
`assets/editor-<UUID>.png` paths. Generations are staged outside the project until
Save, installed exclusively before the manifest commit, and never overwrite existing
assets. Replace preserves all layer/effect semantics except the image resource and
its image contract; aspect ratio changes map into the unchanged quad. Session ownership,
revisions, undo, staging paths and publication receipts are not serialized. Complete
unreferenced generations may remain after failed saves or crashes; no automatic GC.


Save As creates a self-contained new managed native WSS project at
`Wallpapers/WSS/<new UUID>/`, with the confirmed Library/manifest title and the current
Working model. Existing v1 resource references/contracts remain valid inside B, but
all referenced bytes have independent physical ownership. Session-only generations
are copied too. Output is limited to 512 MiB. WSS remains `wss-scene`, version 1;
no new identity, history, toolbar or editor state fields are serialized.

The whole project is validated and exclusively published before the new Library entry
is atomically persisted, which is the Save-As commit point. Failed Library publication
can leave a complete unreferenced project; no automatic GC or journal. A is unchanged.
Successful Save As switches the same editor window to clean B with empty Undo/Redo,
without changing desktop or playlist references. Normal Save retains its separate
manifest-last commit contract and active-UUID refresh rule.

The internal scalar-mask editing foundation keeps this v1 format unchanged. An
adopted edit of a supported Ripple/Clouds/Rain mask creates a new
lossless scalar PNG with an explicit linear/clamp/non-mipmapped descriptor, preserving
dimensions and UV scale. Only the selected effect slot references that generation;
other users of a shared original mask retain their original reference. Original files
are never modified. Session target IDs, brush/stroke state and undo are not serialized.
Mask generations use the same catalog, exclusive asset publication and manifest-last
Save as image generations, and are physically copied by Save As. Canvas Brush state,
selected-only overlays and cursor geometry are editor-local and add no format fields.
Supported mask creation/painting and Flow field/region editing use independent immutable generations and the same save safeguards; see [the editor guide](docs/EDITOR.md).
