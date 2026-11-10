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

There are 1…128 ordered image, Rain or CursorTrail layers, drawn from first to last. Existing image entries without `type` retain exactly their former meaning; `type: "image"` is also accepted. Each image layer has:

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
- `effects`: optional array, default empty; ordered Flow/Ripple/Clouds stages, including mixtures and repeats, subject to the [shared effect budgets](docs/effects/COMMON.md#ordered-stacks).

All numbers must be finite. Center/rotation magnitudes and resulting transform
components are limited to 1,000,000. PNG origin/UV is top-left; the existing image
vertex mapping relates it to canvas coordinates. Raster density does not change
logical geometry or animation speed.

## Clouds and mask

Clouds parameters, JSON spellings and examples belong to the [Clouds contract](docs/effects/CLOUDS.md).
Image-mask effect strength and coordinates belong to [shared image rules](docs/effects/COMMON.md#shared-coordinates-and-validation).

A Clouds/Ripple mask may also use the same explicit asset object as an image:
`asset`, `encoding`, `width`, `height`, `uvScale`, `filter`, `edge`, `mipmapped`.
This v1 spelling preserves explicit padded source UVs;
string PNG references retain their existing behavior. Mask contracts require
`filter: "linear"`, `edge: "clamp"`, `mipmapped: false`; image encoding/dimension/path
validation also applies. Conflicting contracts for one asset are rejected. Older
readers reject the object spelling rather than silently losing its UV scale.

Scalar masks use linear red intensity and clamped edges. Channel decoding does not
use the color-image premultiplication/conversion path. Unsupported layouts,
including nonopaque premultiplied mask data, are rejected. Layer-specific UV and
coverage semantics belong to the corresponding effect/layer contract.

## Asset and resource boundary

String image references support files ending in `.png` with a PNG signature, a single image and supported 8-bit decoded pixels. Assets are at most 8192 per axis and 32 Mi pixels.
Native image reads are bounded to 128 MiB per asset. The base decoded-image accounting limit is 128 MiB and includes allocated field/region/Rain texture contributions. Scalar masks have a separate 32-MiB resource-owner limit. All referenced assets, including hidden layers, must be readable during preparation/import.

Explicit image descriptors contain exactly asset, encoding, width, height, uvScale, filter, edge and mipmapped. encoding image accepts a single PNG/JPEG payload whose decoded dimensions equal the declared dimensions; encoding rgba8 requires exactly width×height×4 straight RGBA bytes. Dimensions are 1…8192 with at most 32 Mi pixels; uvScale contains two finite components in (0,1]. filter is linear or nearest; edge is clamp or repeat; mipmapped is boolean. The same asset cannot have conflicting descriptors. These are native data contracts, not external texture containers. Mask descriptors additionally require linear/clamp/non-mipmapped sampling and valid scalar data.

Example explicit image value:

```json
{"asset":"assets/background.png","encoding":"image","width":1920,"height":1080,"uvScale":[1,1],"filter":"linear","edge":"clamp","mipmapped":false}
```

Paths are nonempty, relative, slash-separated components. Empty components, `.`
and `..`, backslashes, NUL, colons, absolute paths and tilde paths are rejected.
Root/asset paths may not traverse symlinks. Managed import also rejects symlinks
and special files throughout the complete source directory. Scene JSON reads are bounded to 2 MiB; file reads are bounded as specified above. Hidden/neutral stages do not bypass validation. Asset errors identify WSS data, never an engine shader.

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

See the [Rain layer contract](docs/effects/RAIN.md) for its grammar, example,
parameters, region, mask, composition and instance budget.

## Ripple v1

See the [Ripple contract](docs/effects/RIPPLE.md) for required/optional JSON,
parameters, mask semantics and compatibility.

## Flow and ordered stacks

See the [Flow contract](docs/effects/FLOW.md) for descriptors, byte formats and
JSON; [shared stacks](docs/effects/COMMON.md#ordered-stacks) define ordering and budgets.
The [Ripple contract](docs/effects/RIPPLE.md) owns its spatial extension fields.

## Non-destructive native editing

The editor works on a typed native document and independently owned immutable asset generations. Import copies source content; editing the managed copy never rewrites the external original. Missing/invalid project data is an error, never permission to regenerate it. Runtime history and editor session state are not serialized. See [editor workflows](docs/EDITOR.md) and [architecture](docs/ARCHITECTURE.md).

## Native cursorTrail layer

See the [CursorTrail contract](WSS-TRAIL.md) for its v1 layer grammar, JSON example,
parameter/encoding rules, simulation, authoring and scene-wide history budget.

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
