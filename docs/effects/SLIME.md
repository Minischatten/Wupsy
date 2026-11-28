# Slime

Slime is a sortable native WSS layer. The hanging filament stretches, releases
one drop per cycle, and retracts to its anchor. Direct Drop grows and releases
one drop from the same kind of anchor without forming a long filament. Preview and desktop playback use
the same analytic Metal renderer. The scene clock supplies time, so evaluating
a frame does not depend on earlier frames or on the display refresh rate.

## WSS v1

A Slime layer has `type: "slime"`, a required `transform`, and a required
`slime` object. Optional `visible` defaults to true. Optional `name` follows
the shared layer naming contract. All properties in the table except `mode`, `reflectionColor`, and `cycleOffset` are required in JSON.
Defaults apply when adding Slime in the editor.

| Key | Default | Range and meaning |
|---|---:|---|
| `mode` | `hangingThread` | Optional. `hangingThread` or `directDrop`. The encoder omits the default. |
| `color` | `{red:0.13, green:0.26, blue:0.15}` | SDR sRGB components, each 0…1 |
| `reflectionColor` | `{red:0.87, green:0.97, blue:0.93}` | Optional SDR sRGB components, each 0…1. Tints both reflection zones. |
| `opacity` | 1 | 0…1, composited opacity including highlights |
| `gloss` | 1 | 0…2, reflection strength |
| `width` | 18 | 9…36 scene px, full tube diameter at the first centerline sample |
| `length` | 97 | 24…300, maximum scene-pixel length of the 12-segment filament centerline at release, subject to fit within the fall distance |
| `speed` | 1 | 0…3, cycle rate multiplier. At 1, the minimum period is 7 seconds for Hanging Thread and 2.4 seconds for Direct Drop. At 0, the layer rests at its anchor. |
| `cycleOffset` | 0 | Finite normalized phase in `[0, 1)`. The inspector edits it as 0…99%. |
| `dropSize` | 19 | 9.5…38 scene px, full drop diameter perpendicular to the fall direction at release |
| `direction` | 180 | 0…360°, in scene coordinates. 0° is up, 90° right, 180° down and 270° left. This aims the hanging filament and the released drop. |
| `distance` | 258 | 24…9,159 scene px from the anchor center to the final drop-center projection on the fall axis |

The transform uses the shared lower-left scene coordinates and radians.
Its center places the anchor. Effective width and height (`size × scale`)
must each be 4…128 logical scene units. The rotation handle turns the attachment pad to match the surface. The two
size controls scale the pad along its own axes. Width, filament length, drop
diameter and endpoint are stored in scene pixels and keep their geometric
meaning when either pad axis changes. The vertical size retains its previous
influence on falling acceleration. Nonuniform scaling cannot turn the
falling trajectory. The filament starts
along the pad normal, then turns smoothly toward gravity. Near opposing
directions the initial turn softens to avoid folding back over the pad. The
hanging drop and neck follow the actual filament tip and its tangent. On release
the drop starts from that same position and accelerates along the scene axis.

New layers start at half the canvas width and about 77% of its height. The
static editing Canvas shows the resting anchor, and the same geometry model
drives editor Live Preview and desktop playback. Existing internal Slime files
use the scene-relative direction directly, without migration or a legacy mode.
The [alignment fixture](../../Test-Wallpaper/WSS-Slime-Alignment-v1/scene.wss.json)
contains five attachments and synthetic surfaces.

The offset advances the whole cycle by the stored fraction of a cycle and
wraps at the end. Speed remains independent. At zero speed the anchor rests
at phase zero and the offset remains stored. A missing offset defaults to
zero. Saving writes it explicitly. Strict Slime readers without this field
reject manifests that store it.

The editor places a new Slime layer at the midpoint of the largest gap between
stored phases, including the wrap from the last phase to the first. Ties use
the gap with the lowest start phase. Starting with an empty scene gives
0%, 50%, 25%, and 75% for the first four additions. Duplicate copies the
source value. Reorder, delete, save and reopen keep existing values.
Internal WSS values above 99% are displayed at the inspector's 99% ceiling
and preserved until edited. See the [four-cycle fixture](../../Test-Wallpaper/WSS-Slime-Cycles-v1/scene.wss.json).

The inspector allows at least 450 scene pixels and expands to the rounded
canvas span projected on the configured fall axis. A previously stored value
stays editable when the projection shrinks. The finite schema cap is the
rounded diagonal of the largest allowed canvas (8192 × 4096).

In E.1, the distance began at the drop center at the instant of release.
In E.2, the center of the attachment pad is the origin. The analytic
centerline retains its curve, and its 12 rendered segments are normalized to
the requested arc length at release. The hanging drop center includes the
tip's tangent offset. Only the signed projection of that entire offset
from the anchor onto the fall axis counts toward the endpoint. The detached
drop retains the release position perpendicular to the fall axis.

If the hanging geometry would leave less than 12 px or a quarter of the
total distance (whichever is smaller), the renderer proportionally shortens
the filament and the hanging drop's center offset throughout the cycle.
The entered length remains the maximum and the drop's diameter stays
independent. The filament tapers, gathers and retracts as before. Drop width
and height still vary organically around the specified reference diameter.

After release the center travels with quadratic acceleration up to the
remaining distance. The drop fades smoothly to zero as its center reaches
the endpoint. The fade starts up to 42 px times the longitudinal pad scale
before that point, limited to 42/147 of the remaining travel. The nominal
endpoint is therefore the point of zero opacity, rather than a hard cutoff
at the drop outline. The minimum
cycle is seven animation seconds. Long falls extend it to completion plus
50 ms. Viewport zoom, backing scale and preview size only change output
projection. The [spatial fixture](../../Test-Wallpaper/WSS-Slime-Spatial-v1/scene.wss.json)
shows three pad sizes, filament lengths and drop diameters at 800 px each.

### Direct Drop

The anchor is still the center of the pad, with the existing transform,
rotation and effective pad dimensions. At normal tempo the drop grows over
0.85 animation seconds. Its center moves smoothly along the scene fall axis
to the release point, while its radii and coverage grow from a nearly invisible
bulge. The transverse diameter equals the stored reference size at release.
The free fall begins with the same center, shape and coverage. The release
offset counts toward the configured anchor-to-endpoint distance. A short fall
reduces this offset to reserve a visible free-fall segment.

The same quadratic fall and fade functions apply to the remaining travel,
including acceleration scaled by the pad's longitudinal size. Coverage reaches
zero at the endpoint. The cycle lasts at least 2.4 animation seconds and is
extended, if needed, to the end of the fall plus 50 ms. Speed scales the entire
cycle, speed zero shows the resting pad, and cycle offset advances the whole
cycle by its stored fraction. Each cycle contains at most one drop.

The inspector hides filament width and length for Direct Drop. Both values
are still saved and become editable again when switching to Hanging Thread.
Changing the mode keeps all parameter values, including speed and cycle
offset. The two modes can show different poses at the current scene time
because their periods differ. Undo, duplication and reopening preserve the
mode. Existing files without a mode retain Hanging Thread and the existing
cycle. Older strict readers reject the new `mode` field on Direct Drop files.
See the [synthetic mixed-mode fixture](../../Test-Wallpaper/WSS-Slime-Direct-Drop-v1/scene.wss.json).

Slime blends source-over in layer order. Each visible active layer draws
one bounded local quad while shapes overlap, or two disjoint quads when the
drop is separate. The empty gap uses no fragments. Both draws use the same
render pass and share a pipeline with the other Slime layers.
It owns no external assets, offscreen textures, or per-display simulation
state. A scene may declare up to 16 Slime layers, including hidden layers,
within the general WSS layer limit. Hidden and zero-opacity layers skip
drawing. A visible layer with nonzero opacity and speed requires animation.

Unknown fields, null parameters, and values outside the stored limits fail
validation. The native SDR color well exposes reflection color directly below
material color. Material color tints the body, reflection color tints the
highlights, gloss sets their strength, and opacity controls the composite.
Reflection color has no effect at zero gloss.

An omitted reflection color uses the original Phase 2 color. Saving omits the
field when it equals the default, even if it was explicitly present on load.
Phase 2 readers without this extension reject a stored nondefault
`reflectionColor` as an unknown field. Older versions without Slime support
reject the unknown layer type. Published effects keep their previous meaning. Internal Slime files have no
legacy path for the former width/drop multipliers or the release-relative
distance. See the [synthetic
two-layer fixture](../../Test-Wallpaper/WSS-Slime-v1/scene.wss.json).
