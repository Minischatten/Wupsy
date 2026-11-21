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

Reset to Defaults restores the configuration while retaining the movement
rectangle, layer order and visibility.
