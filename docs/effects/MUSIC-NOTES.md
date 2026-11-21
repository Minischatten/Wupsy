# Music Notes

Original Wupsy implementation and artwork. The built-in 192 × 64 R8 atlas
contains three hand-defined geometric silhouettes (angled oval heads, stems,
curved flag and beam), rasterized with 4 × 4 supersampling into three 64 × 64
tiles. The atlas is covered by the project license and uses no font or external
artwork.

A WSS-v1 layer has `type: "musicNotes"`, an optional `visible` flag (default
true), a required `region` and a required `musicNotes` configuration. The region
uses logical canvas coordinates (lower-left origin). Each dimension is 1…8192,
area is at most 32 Mi logical square units and origin components are bounded to
±1,000,000. The editor initially fills the canvas and supports moving and
scaling the axis-aligned rectangle.

| Field | Default | Bounds |
|---|---|---|
| `count` | 12 | Integer 0…128 |
| `size` | 48 | 4…192 logical units, further capped at 48% of the smaller region side at draw time |
| `color` | white | SDR sRGB `red`, `green`, `blue` components in 0…1 |
| `opacity` | 0.85 | 0…1 |
| `direction` | 90 | 0…360°, counterclockwise from right |
| `speed` | 24 | 0…256 logical units/sec |
| `hover`, `rotation` | false, false | Independent Boolean switches |
| `seed` | 1 | UInt32 |
| `symbols` | quarter, eighth, double | Nonempty ordered array of unique IDs from those three choices |

All configuration fields are required. Unknown fields, nulls and invalid
parameters are rejected even on hidden layers. A scene permits up to eight
declared layers and 512 declared notes including hidden layers. A reader
without support for the layer rejects its type. Scenes with no Music Notes
layer use the existing render preparation.

A NOTE stream of the existing SplitMix64 generator produces stable positions,
symbol selectors and motion phases. Prepared resources share one atlas and
one 2 KiB immutable buffer per distinct seed across the layers. Compatible
preview edits reuse these resources. The shader uses bounded phases from the
shared clock. One instanced draw per visible, nonempty layer composites
premultiplied source-over at its painter-order position. Wrapped quads continue
at the opposite edge and feather into the rectangle. Hover oscillates perpendicular
to travel (vertically at zero speed), at 0.23 Hz and 12% of the drawn note size.
There is no timed gap at slow speeds. A note uses at most four quads, with
nonintersecting copies degenerate. An abrupt direction edit can reposition
notes in the live preview. A layer with zero count or opacity does not animate, nor does a
layer with zero speed and both motion switches off.

The inspector offers numeric speed and angle editing, a direction grid and
the native SDR color well. The speed slider updates its own numeric display
during dragging and commits one model/preview update on release. The static
editing canvas shows the region frame, and the Live Preview shows the notes.

Reset to Defaults restores the configuration and switches to linear movement.
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
  second anchor's incoming grip. Open paths have 2…16 anchors. Closed paths have
  3…16 and implicitly join the last to the first.
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
validation. The check compares both interpolants at the same cumulative distance.

Each entry occupies 16 bytes (two Float32 position components and two
Float32 unit tangent components). The table has 4,112 or 8,208 bytes of
entry payload, plus its separate origin and length. Positions are offsets
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
uses the local normal with the existing 0.23 Hz and 12% size amplitude.
Its amplitude tapers locally if nearly opposite tangents cancel. Rotation
keeps the existing frequency and amplitude.

A prepared path uploads 4,112 or 8,208 bytes of immutable sample data.
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
editable S-curve within the movement rectangle. Linear keeps the saved curve,
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
within the path limits. Closing a two-anchor curve first splits its original
segment to supply the required third anchor. The closing segment uses the
existing endpoint grips, or extends their tangents where a grip is collapsed
and the rectangle permits it. If that join exceeds the sampling limits, the
editor tries alternative closing grips while preserving the original segments.

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
