# Music Notes

Original Wupsy implementation and artwork. The built-in 256 × 256 R8 atlas
keeps the original three 64 × 64 geometric note tiles in its top row.
A separate padded 96 × 192 tile contains the treble clef, drawn from original
Bézier contours and rasterized with 4 × 4 supersampling. The atlas is covered
by the project license and uses no font or external artwork. The clef samples
its own tall tile and uses a quad that is half as wide as it is high, so
`size` still denotes the long axis of the quad. Rotation uses the same
centered local coordinate system as the square legacy symbols.

A WSS-v1 layer has `type: "musicNotes"`, an optional `visible` flag (default
true), a required `region` and a required `musicNotes` configuration. The region
uses logical canvas coordinates (lower-left origin). Each dimension is 1…8192,
area is at most 32 Mi logical square units and origin components are bounded to
±1,000,000. The editor initially fills the canvas and supports moving and
scaling the axis-aligned rectangle. Music Notes previously inherited the
general proportional corner drag unless Shift was held. Its corners now
resize both dimensions independently, and midpoint handles resize only the
corresponding dimension. The opposite edge or corner stays fixed. Region
resizing keeps the normalized anchors and grips, rebuilds playback and staff
geometry in logical canvas coordinates, and preserves the staff spacing.

| Field | Default | Bounds |
|---|---|---|
| `count` | 12 | Integer 0…128 |
| `size` | 48 | 4…512 logical units, further capped at 48% of the smaller region side at draw time |
| `color` | white | SDR sRGB `red`, `green`, `blue` components in 0…1 |
| `opacity` | 0.85 | 0…1 |
| `direction` | 90 | 0…360°, counterclockwise from right |
| `speed` | 24 | 0…256 logical units/sec |
| `hover`, `rotation` | false, false | Independent Boolean switches |
| `hoverStrength` | 12 | Optional, 0…25% of drawn symbol size |
| `hoverFrequency` | 0.23 | Optional, 0.05…1 Hz |
| `rotationStrength` | 100 | Optional, 0…200% of the original 0.32-radian rocking amplitude |
| `rotationFrequency` | 0.13 | Optional, 0.05…1 Hz |
| `seed` | 1 | UInt32 |
| `symbols` | quarter, eighth, double | Nonempty ordered array of unique IDs from `quarter`, `eighth`, `double`, `trebleClef` |

A 512-unit draw in a region-capped mode requires both region sides to be at least roughly 1067
logical units. The requested size remains in the manifest even when the
region limits the drawn size. The same 64-pixel atlas tiles are filtered
when enlarged, so very large silhouettes can look softer.

All configuration fields except the four motion overrides are required.
Omitted overrides use the original values above. Unknown fields, nulls and invalid
parameters are rejected even on hidden layers. A scene permits up to eight
declared layers and 512 declared notes including hidden layers. A reader
without support for the layer rejects its type. Earlier readers reject the
`trebleClef` ID. It is an opt-in choice and is excluded from new-layer and
reset defaults. The symbol uses the existing linear and path movement and
shares color, opacity, hover and rotation with the other choices. Scenes with no Music Notes
layer use the existing render preparation.

A NOTE stream of the existing SplitMix64 generator produces stable positions,
symbol selectors and motion phases. Prepared resources share one atlas and
one 2 KiB immutable buffer per distinct seed across the layers. Compatible
preview edits reuse these resources. The shader uses bounded phases from the
shared clock. One instanced draw per visible, nonempty layer composites
premultiplied source-over at its painter-order position. Wrapped quads continue
at the opposite edge and feather into the rectangle. Hover oscillates perpendicular
to travel (vertically at zero speed). The default frequency is 0.23 Hz
and the default amplitude is 12% of the drawn note size. Gentle rocking is an
independent in-plane oscillation with a default frequency of 0.13 Hz and
amplitude of 0.32 radians (about 18.3° in each direction). The shader keeps
the same seeded phase offsets for both movements. The existing switches and
a strength of zero suppress the corresponding movement without discarding
its settings.
There is no timed gap at slow speeds. A note uses at most four quads, with
nonintersecting copies degenerate. An abrupt direction edit can reposition
notes in the live preview. A layer with zero count or opacity does not animate, nor does a
layer with zero speed and neither additional movement active.

The inspector offers numeric speed and angle editing, a direction grid and
the native SDR color well. Gentle Motion offers separate strength (%) and
frequency (Hz) sliders and numeric fields for hover and rotation. Slider
changes update Live Preview during the drag, with one Undo step per gesture. The speed slider updates its own numeric display
during dragging and commits one model/preview update on release. The static
editing canvas shows the region frame, and the Live Preview shows the notes.

Reset to Defaults restores the notes and staff settings and switches to linear movement.
It retains the movement rectangle, layer order, visibility and any saved curve.

## Stage 2.1 path data and geometry

A music notes layer can contain one optional layer-level `path` object.
Omitting it preserves the original manifest spelling. If present, the four
fields below are required. The object and its anchors reject unknown fields
and explicit nulls. Older strict readers reject layers with this field.

```json
{
  "enabled": true,
  "closed": false,
  "direction": "forward",
  "anchors": [
    {"position":[0.1,0.2],"incoming":[0.1,0.2],"outgoing":[0.25,0.55]},
    {"position":[0.9,0.7],"incoming":[0.65,0.65],"outgoing":[0.9,0.7]}
  ]
}
```

- `direction` accepts `forward` or `reverse`. Preparation always follows authored
  anchor order. Playback traverses the table in the configured direction.
- Every position and grip is an absolute normalized pair within the region's
  lower-left coordinate frame. Both components are finite and in 0…1. A segment
  connects an anchor to the next using the first anchor's outgoing grip and the
  second anchor's incoming grip. Open and closed paths have 2…16
  anchors. Closed paths implicitly join the last to the first. Older readers
  that required three closed anchors reject a two-anchor closed path.
- Consecutive anchors, including the closed join, must differ by at least 0.01
  logical canvas units after X/Y scaling. Identical adjacent anchors and
  effectively zero segments are rejected. Collapsed grips, nonadjacent repeated
  positions and self-crossings are allowed within the preparation limits.
  Hidden layers and disabled paths use the same validation. Disabling a path
  preserves its geometry in the manifest.

The CPU adaptively subdivides cubic segments in logical canvas units using a
per-piece chord deviation and control polygon excess tolerance of at most
0.01 units. Short segments lower the tolerance to 0.01% of the original
control polygon length. Subdivision allows at most 16 levels and 4,096
accepted edges across the path. Cumulative chord lengths define the
approximate path length and the equally spaced table entries.

Preparation prefers 257 entries when every table chord covers at least 96%
of its nominal interval and interpolation deviates from the flattened curve
by at most the smaller of 0.25 units and 8% of an interval. Otherwise it tries
513 entries. Intervals without an interior anchor join must cover at least
90% of the nominal distance and deviate by at most the smaller of 1 unit and
12% of the interval. At an authored join, the deviation may reach the smaller
of 2 units and 49% of the interval. This allows sharp corners, which can still
reduce local speed within that interval. Paths exceeding these bounds fail
validation, except that a closed path can additionally try 1025 and 2049
entries. In those tables the joins and return segment can deviate by up
to half an interval, capped at two units, and allow shorter chords at tight turns. This preserves the authored return segment across sharp
joins. The check compares both interpolants at the same cumulative distance.

Each entry occupies 16 bytes (two Float32 position components and two
Float32 unit tangent components). The original tables use 4,112 or 8,208 bytes and remain unchanged when they
meet the bounds. Refined tables use 16,400 or 32,784 bytes. In all cases origin
and length are stored separately. Positions are offsets
from the first anchor in logical canvas units. The table origin is relative
to the movement region. Tangents are estimated from adjacent samples, with
a one-sided fallback at reversals. Closed tables duplicate the first
position and tangent at the final entry. A smooth authored join yields a
smooth sampled join. The table is derived CPU data and is never serialized.

## Stage 2.2 Metal path playback

An enabled path replaces linear movement. Missing and disabled paths use the
Stage 1 render path, including its region wrap and edge feathering. Path mode
uses the region as its coordinate frame. Sprites at the boundary can extend
beyond it and are cropped by the ordinary canvas projection.

The renderer spaces notes at half-slot offsets along the path. Speed is in
logical canvas units per second, with period equal to length divided by speed.
At speed zero the notes stay at those offsets. Hover and rotation can animate
independently. The CPU reduces playback time to one shared normalized phase
per active layer. Each vertex reads and interpolates two adjacent 16-byte
entries by direct index. Every path note uses a single quad and layers still
draw once in painter order with the existing atlas, instance buffer and
premultiplied source-over composition.

Open paths fade to zero at the end and restart at zero opacity. The fade at
each end corresponds to 0.25 seconds at the current speed where possible, capped
at 20% of the path per end. A small normalized lower bound protects Float
evaluation at extreme low speeds. Stationary notes are fully visible. Closed
paths use their duplicate endpoint with no fade. Reverse travel reverses the
table coordinate and keeps the authored tangent convention for hover. Hover
uses the local normal with the same configurable strength and frequency.
Its amplitude tapers locally if nearly opposite tangents cancel. Rotation is independent of the path tangent. The tangent does not align the
symbol artwork to the path.

A prepared path uploads 4,112 or 8,208 bytes for the regular tables, up to
32,784 bytes for a refined closed path.
Document path copies cache one CPU table by curve and region dimensions.
Compatible preview changes reuse GPU tables when the curve and dimensions
match, including direction, speed, visibility or translation edits. Geometry
and region size changes replace the affected table. A disabled path loaded
from disk needs no GPU table. Disabling an already prepared, unchanged path
can retain its buffer for reuse. The preview keeps the renderer and running
playhead for compatible updates. In-flight draws retain the old resource
snapshot through completion.

Very short paths at high speeds can complete a cycle between display frames,
so an open-path fade can be undersampled or missed. Speed is never clamped.
Changing the direction, curve or period while playing can reposition notes at
the current playhead. A sharp authored join can reduce local apparent speed.
The [asset-free path fixture](../../Test-Wallpaper/WSS-Music-Notes-Paths/README.md)
contains an open S-curve and a closed reverse ellipse for desktop or Live
Preview review.

## Stage 2.3 path authoring

Use the Music Notes inspector to switch between Linear and Path, choose
Open or Closed and select Forward or Reverse. The first activation creates an
editable horizontal line with two anchors within the movement rectangle.
Linear keeps the saved curve,
and activating Path restores it. Delete Path removes the saved curve as a
separate undoable action. Reset to Defaults selects linear motion and preserves
the curve.

A selected visible layer with an active path shows a passive curve alongside
the normal transform handles. Linear movement hides that curve.
Edit Path replaces the rectangle handles with a thin, noninteractive blue guide
for the same movement bounds. The curve overlay and its anchors remain editable. The selected anchor
shows its incoming and outgoing grips where they participate in a segment.
The square marks the start of open travel, the orange dot its end and the arrow
shows direction. Drag an anchor to move it and its two grips within the
rectangle. Drag a grip to adjust its side independently. Very short or
collapsed grips have a screen-space handle so they remain reachable when zoomed
out. Double-click a segment to split it with de Casteljau subdivision, which
preserves the cubic shape. Delete or Backspace removes the selected anchor
within the path limits. Open/Closed only adds or removes the closing segment
and preserves every anchor and grip, including on a two-anchor path that
retraces itself. The Path Templates menu explicitly replaces the curve with
an open straight line or a closed four-anchor ellipse in one Undo step. It
keeps the existing travel direction and all non-path settings, including
staff and depth-change percentages. Grip previews transition smoothly near
a collapsed handle. An active drag uses the window-pointer displacement at
its initial Canvas scale so a layout update alone cannot move a control point.


In Edit Path, **Smooth Anchor** aligns the selected anchor’s active grips
along the bisector of the incoming and outgoing chord directions in Canvas
units. The action keeps shorter nonzero grip lengths and caps each grip at
one third of its neighboring chord. Collapsed grips start at that cap.
Frame bounds shorten the grips along the shared axis. Open endpoints use the
single adjacent chord and preserve their unused grip. Closed paths wrap the
neighbor lookup across the seam. Near reversals, closed two-anchor paths,
or a frame edge that leaves no room for an active grip leave the curve as it
was. A valid change is one Undo step. Ordinary dragging and insertion retain
their existing behavior. Depth and perspective values retain their authored
percentages along the resulting curve.

The curve overlay redraws with the pointer. The existing Live Preview receives
only valid drafts, at most about 30 times per second. It shares the playback
clock, atlas and instance resources for compatible geometry updates. The large
Canvas remains a static image composition with the path overlay. On release the
latest valid draft becomes one Undo step. Escape restores the original curve
during a drag, or leaves Path Editing when idle. Leaving the mode restores the
rectangle handles. Saving, selecting another layer, and other editor
transaction boundaries finish the current drag. If a candidate violates the
geometry or sampling limits, the last valid curve remains the working value.

The inspector shows a quiet hint when the open-path fade would span fewer than
two frames at the editor preview rate. It does not change the stored speed.

## Stage 3.1 staff data and geometry

A Music Notes layer can carry an optional layer-level `staff` object alongside
`path`. Omit it for a layer with no staff configuration. The object is
preserved when disabled, and all five fields are required when present.

| Field | Model default | Bounds |
|---|---|---|
| `enabled` | false | Boolean |
| `spacing` | 12 | 1…256 logical canvas units |
| `width` | 1.5 | 0.25…64 logical canvas units, strictly less than spacing |
| `color` | white | SDR sRGB `red`, `green`, `blue` components in 0…1 |
| `opacity` | 0.45 | 0…1 |

Numeric values must be finite. Explicit null and unknown fields are invalid,
including inside the color object. The same rules apply to disabled staff and
hidden layers. Older strict readers reject a manifest containing `staff`.
Stage 3.1 persists settings and prepares CPU geometry. Stage 3.2 renders it
in desktop playback and Live Preview.

An enabled path supplies the middle line. Preparation uses the existing
adaptive Bézier subdivision in logical canvas units after X/Y scaling. It keeps
authored segment boundaries and uses the incident edge normals there. The
existing equally spaced playback table, validation and animation keep their
Stage 2 behavior. Linear movement uses the line through the region center at
the configured heading, from one rectangle intersection to the other. The
other lines use the same ends shifted by their respective perpendicular offsets.
A disabled saved path is ignored for this calculation.

Five bands are centered at −2, −1, 0, +1 and +2 times the spacing. The mesh
uses flat ends for open lines and the same join at a closed seam as at interior
points. It limits miter length to twice the offset distance, bevels sharper
turns, and uses separate flat cross sections at nearly reversing tangents.
The spacing is preserved as the nominal offset even on tight bends. A CPU
diagnostic flags sharp joins and locally folded offsets; distant
self-intersections remain as authored. Tight offsets and bevels can overlap,
especially on retraced segments. These cases do not invalidate the path.

The triangle list is grouped into five line ranges. Each vertex is a pair of
Float32 coordinates relative to a separate region-local origin. A single-entry
CPU cache is keyed by region size, curve (or linear heading), width and spacing.
A cache miss for a curve runs the same bounded adaptive subdivision as playback
to recover its exact edge sequence. Translation, playback direction, speed,
color and opacity can use the existing mesh. Each of the at most 4,096 edges
contributes at most 12 vertices per line, including the following join.
The maximum is 245,760 vertices (1,966,080 bytes, about 1.875 MiB of vertex
payload per layer). This bound excludes temporary CPU working arrays and cache
metadata. Meshes are derived data and are never serialized.

## Stage 3.2 Metal staff rendering

A visible enabled staff with positive opacity is composited immediately before
its notes, at the same painter-order position. The staff uses independent SDR
color and opacity and is visible at zero note count, opacity or speed. Its
presence does not change note instancing, playback or animation scheduling.

The staff uses the Stage 3.1 triangle list. On a coverage-cache miss one
small render pass writes opaque samples into a memoryless multisample
attachment and resolves them into an R8 texture. Both attachments are clipped
to the projected visible mesh bounds. The device uses eight samples per pixel
where supported and four otherwise. Repeated coverage of the same sample is
idempotent, including at tight folds, joins and self-crossings. In the main
render pass one quad reads the resolved coverage at actual render-pixel
coordinates, applies staff color and opacity once, and composites premultiplied
source-over. Uncovered pixels contribute zero. This preserves existing layer
ordering and keeps backing scale and the main scene target unchanged. Without
a separate coverage pass, direct source-over triangles would accumulate
opacity at overlaps; a per-pixel stencil could prevent duplicates but would
need a stencil attachment and still would not combine fractional coverage at
crossings. Extremely thin strokes can still lose coverage at some subpixel
positions when heavily reduced.

The vertex buffer length matches the triangle list (8 bytes per vertex).
The regression fixtures use 26,880 bytes for the open S-curve and 983,040
bytes for a complex four-turn loop at the 4,096-edge subdivision limit.
The absolute bound remains 1,966,080 bytes per staff, including bevels.
The resolved mask adds one byte per covered bounding-box pixel before
hardware padding. A 600 × 120 box would use about 70 KiB, and a box filling
a 3840 × 2160 target about 7.9 MiB. Up to one completed mask per prepared
staff is cached. In-flight changes can temporarily retain additional masks;
the multisample attachment uses tile memory. With unchanged projection, the
steady-state cost is one staff draw plus the existing note draw if applicable.

Geometry keys include region dimensions, enabled curve shape or linear
heading, width and spacing. Style and note playback edits reuse the GPU mesh
and mask. Region translation and projection changes reuse the mesh and rebuild
the projected mask. Masks are published for reuse only after GPU completion.
In-flight command buffers retain their encoded resources through completion.


## Stage 3.3 staff authoring

Use the Music Notes Inspector’s Staff section to show or hide the five lines.
When enabled, the section offers numeric spacing and thickness in logical
canvas units, an SDR color well, and an opacity slider and numeric field.
Numeric fields show their bounds and reject invalid drafts. Thickness must
remain strictly smaller than spacing. A slider gesture updates Live Preview
and registers one Undo step, while field edits, colors and toggles are
independently undoable. Disabling the staff retains its style. Reset to
Defaults removes the optional staff configuration, restoring its off state
and model defaults. It preserves the movement frame and the authored curve
while switching to Linear as before.

The editing Canvas draws the selected visible layer’s staff using the same
bounded triangle mesh as Metal. The passive fill uses canvas coordinates and
shares zoom and pan with the curve overlay, leaving existing transform and
Bézier controls available. It draws during path editing and in transform mode,
including with linear movement. During a drag it follows the draft. If draft
geometry cannot be prepared, the Canvas holds the committed staff while Live
Preview continues through the existing validated update path. The path guide
and its markers draw above the staff. Staff color and opacity apply to the
Canvas fill. App-wide UI scaling applies to the Inspector and existing
handles, independently of staff geometry.
The Inspector shows a quiet hint when the current prepared staff flags sharp
joins or locally folded offsets; it retains the authored spacing.


## Single-symbol placement

The optional layer-level `placement` selects `animatedPath`, `freeSingle`
or `anchoredSingle`. Omission keeps the existing animation, including either
linear or Bézier travel. The existing `musicNotes` settings remain valid and
retain the animation style. The optional `freeSymbol` and `anchoredSymbol`
objects store the independent `symbol`, `size`, `color` and `opacity` for each
single mode. Their defaults are quarter note, 48 logical units, white and
0.85 opacity. Symbols use the existing IDs and validation bounds.

- **Free.** The optional `freePosition` is a pair of finite logical canvas
  coordinates in −1,000,000…1,000,000, with the origin at the lower left. It
  defaults to the center of the movement region. The Canvas draws the neutral
  symbol and supports picking and dragging it, with one Undo step per drag.
  The Inspector also accepts X/Y coordinates. Moving the symbol leaves the
  movement region and stored path unchanged. The full 4…512 size range applies
  without the region cap.
- **Attached.** The optional `anchorPosition` is a finite percent in 0…100,
  default 50. It follows the authored order, independent of travel direction.
  On an open path, 0 and 100 are the separate endpoints. On a closed path they
  coincide. An attached symbol reuses the Bézier playback table and updates as
  the path changes. When the path is disabled or absent, the symbol stays at the
  movement-region center until Path is enabled. The existing region size cap
  applies. Optional Boolean `alignToPath` defaults to false. When active on a
  path, the authored tangent controls the baseline orientation. The existing
  gentle rotation is added to that orientation.

Both modes reuse the atlas and path pipeline with one instance at a fixed
base position and no travel fade or periodic copies. The shared gentle motion
controls still animate the symbol about its base position in Live Preview and
desktop playback. With no active gentle motion, a single symbol does not
advance the playback clock on its own. The static editing Canvas shows the
neutral pose. Lines render only in the animated mode, and mode changes keep
their data and both single-symbol styles. Reset clears the placement overrides
and returns to the previous animated defaults. All new fields are strictly
validated even in inactive modes; explicit nulls and unknown fields are invalid.
Earlier strict readers reject manifests containing these fields.


### Single-symbol rotation modes

The Inspector calls the existing sinusoidal movement Gentle Rocking. The
`rotation`, `rotationStrength` and `rotationFrequency` fields keep their
existing names, ranges and defaults. Animated notes continue to use them.

Each single-symbol style (`freeSymbol` and `anchoredSymbol`) may additionally
store these optional fields:

| Field | Values | Default |
|---|---|---|
| `rotationMode` | `none`, `rocking`, `continuous` | Existing `musicNotes.rotation` decides between `none` and `rocking` |
| `spinPeriod` | 5…300 seconds per revolution | 60 |
| `spinDirection` | `clockwise`, `counterclockwise` | `clockwise` |
| `spinAxis` | `imagePlane`, `vertical` | `imagePlane` |

Continuous rotation and rocking are mutually exclusive. Hover is independent.
Spin settings remain saved when another mode is selected. Metal applies the
signed wrapped turn about the same symbol center, on top of the optional
path tangent. The clock is reduced modulo the period before conversion to
Float. The static editing Canvas continues to display the neutral pose.


The axis selector appears only under continuous rotation. In the image plane
the symbol spins as before. For the vertical axis, the vertex shader
multiplies the local X offset by the signed cosine of the spin angle. The
local height and center stay fixed. Keeping the UVs and disabling face culling
shows the mirrored back. At exact quarter turns the quad collapses without
invalid coordinates. The projection precedes any path-tangent orientation.
The clockwise setting represents the right edge initially moving toward the
viewer; counterclockwise represents the left edge moving toward the viewer.
Under orthographic projection and identical treatment of both faces, both
directions look the same.

## Depth changes

Enable Path in the animated placement mode and choose a source-over image
in the Depth Changes section. Set the starting side and up to eight change
points. Each point starts a new section at its authored percent and has its
own side. Positions must be strictly increasing and greater than 0 and
less than 100. The Inspector supports adding, editing and removing points
with separate Undo actions. The Bézier editor retains its existing handles.
Reset removes the note layer's depth configuration.

The optional layer object `depth` contains `enabled`, `target` (an image
layer UUID), `start` and `changes`. `start` and each change's `side` are
`inFront` or `behind`; each change has a `position` in percent. The image
stores its optional identifier in `depthID`. Reordering or renaming does
not change that identifier. A hidden, missing or ineligible image, an
inactive path, a disabled depth configuration or single-symbol placement
uses the ordinary painter order. The configuration is retained so it can be
restored by Undo or re-enabled. Duplicate image identifiers are invalid.
Scenes without these fields retain their original rendering; older strict
readers reject scenes that include them.

The composition schedules each source's behind notes immediately before
the selected image and its front notes immediately after it, in the same
Metal render pass. The existing final image draw supplies its true alpha
including effects and layer opacity; there is no additional silhouette
texture. The note center's authored path position selects exactly one side,
including in reverse playback. In a closed loop 100% is equivalent to 0%;
a different final section and starting side produce a defined depth change
at that crossing. A side switch under an opaque silhouette can immediately
cover or reveal part of the note without changing its position or size.
Staff lines remain at the original layer slot by default. Other draws retain their
relative order; the depth-routed notes are now ordered at the target, so
layers originally between source and target can cover or be covered by them.

Depth routing adds one instanced draw per active source, a 48-byte uniform
payload per path-note draw, and no new textures or persistent GPU buffers.
The bounded shader test checks at most eight points per vertex. The routing
plan is prepared with each resource snapshot. Playback and its clock are
shared with regular path notes.


### Apply depth changes to staff lines

The Inspector offers Notes Only (the default) and Notes and Staff Lines
when staff is enabled and a visible source-over image is selected. Optional
`depth.includesStaff: true` applies the same sections to all five lines.
Omitted or false retains the original staff draw. A missing, hidden or
ineligible target restores the original order for both symbols and staff.

Staff triangles carry the normalized cumulative distance of their
centerline endpoints. The existing coverage pass interpolates this value
at each MSAA sample, including when a boundary cuts through a triangle.
The authored path controls all five bands together. Closed paths map 100%
to 0% as for symbols; each face of the seam uses its adjacent section.
The shader and mesh keep the original position, spacing and width.

The same R8 mask encodes disjoint front and back sample counts. At a
self-intersection where areas of different depths overlap, the front
section wins at each overlapping sample. This avoids applying staff opacity
twice. The main pass composites these counts on their respective sides of the
image draw and accounts for mixed coverage at antialiased boundaries.
No separate mask texture, new pipeline or per-line draws are needed.

The optional GPU distance buffer uses four bytes per existing vertex,
up to 983,040 bytes per routed staff. The cached mask uses the same dimensions
and storage as before. A coverage-cache miss adds one mesh draw. The
composite adds one quad draw per routed staff. Moving depth boundaries
invalidates coverage but reuses the geometry and vertex buffers.

## Perspective along the path

The Perspective inspector controls apply to animated notes on an active open
path. Enable Perspective to use the default 100% at the authored start and
30% at the end. Use Swap Start and End to reverse the size gradient
independently of travel direction. Values are 10…200%. Both endpoints
interpolate linearly over normalized arc length, so the default center factor
is 65%. A closed or disabled path suspends the effect and retains its saved
values, avoiding a discontinuity at a closed join. Selecting Linear or a
single-symbol placement also suspends the effect. Reset clears the settings.

The optional layer object `perspective` takes `enabled`, `start` and `end`.
All fields are required when present and validated even while disabled.
Omitted, disabled and enabled 100%/100% settings use the original geometry
and renderer behavior. Older strict readers reject this optional field.

The Metal path shader multiplies the usual drawn symbol size by the local
factor and still caps the result at 512 units and 48% of the smaller region
side. Hover amplitude uses the resulting symbol size. The path position,
travel speed and rocking angles are unchanged. The shader receives a
16-byte uniform vector; no new textures, pipelines, instance data or draw
calls are required.

The same factor scales the stroke offsets and widths at each flattened
centerline sample. The staff holds the original centerline, sample
positions, topology and vertex limits. Only an effective perspective change
invalidates staff geometry and coverage. The editing Canvas uses that same
mesh. The depth sections still use the original arc-length percentages and
the existing mask counts, with unchanged alpha and painter-order rules.
