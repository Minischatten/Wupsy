# Native WSS cursor trail

The native, texture-free cursorTrail layer is editable in Wupsy. Its mathematical geometry and historical provenance limits are described in [the curve contract](docs/CURSOR-TRAIL-CURVES.md). No reference images, video pixels, captured pointer tracks or external curve implementation are included.

## Parameter contract

`WSSTrailConfiguration` is a Codable value DTO, validated before simulation.
It is saved as JSON and edited without making the value model depend on Metal.
It is used directly by the cursorTrail scene-layer grammar. All parameters are required except optional `maxLength` and `curveSmoothing`; all numerical values must be finite. Unknown color components are rejected too.

| Field | Meaning |
|---|---|
| colors | 1–16 explicit linear RGB colors, components 0…1; uniformly spaced palette stops |
| colorMode | sampleRandom: seeded scalar per emitted point, linearly sampled palette; ageGradient: palette sampled at age/lifetime |
| width | full geometric ribbon width in logical canvas pixels; 0 < width ≤ 256 |
| curveSmoothing | optional on input; finite Float 0…0.5, absent defaults to 0.15; UI: Kurvenauslenkung / Curve amount; reset to 0.15 |
| maxLength | optional finite Float spatial history limit, >0…16384 logical canvas pixels; absent means unlimited; null rejected |
| lifetime | seconds, 0 < lifetime ≤ 10 |
| emissionRate | samples per active second, 1…512; subject to the scene-wide budget below |
| fadeIn / fadeOut | seconds; nonnegative, sum ≤ lifetime; linear ramps with plateau if any |
| opacity | 0…1; multiplied by age envelope and cross-section coverage |
| edgeSoftness | 0…1; inward smoothstep edge width as fraction of ribbon half-width; derivative antialiasing remains at zero |
| seed | UInt32, deterministic palette randomization |

All fields except absent `maxLength` are encoded explicitly, including `curveSmoothing`.
Old projects missing `curveSmoothing` load cleanly at 0.15; explicit null rejects. Decode then validate (or construct the validated
simulation). Opening older files does not write them; older strict readers may reject
new saves containing `curveSmoothing`. Existing files retain their palettes and timing values. Unknown JSON fields and null values are rejected by the native document validator.
Palette colors interpolate in linear RGB, not HSV; no hidden tint or implicit reference palette.
New authored layers use the cyan/orange palette and ageGradient; existing palettes and modes are preserved.

## Simulation and rendering

The first valid pointer anchors a sampling epoch. New samples have timestamps
`epoch + index/rate`; positions linearly interpolate between supplied pointer
observations. Existing points do not move. Sampling continues at rest. At one
lifetime old a sample expires; fully coincident segment neighborhoods draw nothing.
No velocity force, width response to speed, hide timer or fixed spatial resampling.
Pointer loss, backwards time or a gap greater than lifetime resets the trail;
the integrated native player resets state on stop/restart and wallpaper changes.
These are documented native choices, not claims of exact historical WE behavior.

Connection geometry, subdivisions, normals and Float-order compatibility are defined
in the [curve contract](docs/CURSOR-TRAIL-CURVES.md#mathematical-requirements).
`curveSmoothing` changes handle reach, not temporal smoothing; zero stays on the chord,
larger values may overshoot. Color/alpha interpolation and configured width are unchanged.
The geometry helper knows no ages or opacity values. The retained default is a
compatibility choice, not a claim about its historical origin.
Metal computes smooth transverse coverage analytically and blends SourceAlpha/One
RGB, preserving destination alpha. There is no texture lookup, extracted texture
profile, bloom or offscreen blur. Age-based alpha remains unchanged and independent
of curve amount, as do lifetime, emission, stillness and pointer-loss behavior.
CPU tessellation and a fresh vertex buffer per draw are the accepted initial
implementation; commands retain their own buffers through GPU completion.

The player owns simulation separately from immutable prepared resources. No properties
of completed image/rain scenes change when no trail is present.

Coordinates use logical canvas pixels with upward Y; caller supplies a matching
viewport. The live player uses SceneCursor centered cover-crop conversion, as images do,
independent of drawable backing scale; deterministic tests
supply explicit positions and do not poll the real mouse.

## JSON layer contract

Version 1 accepts a general procedural cursor trail at its serialized position in
painter order. `visible` defaults true when absent. Save uses the normal scene
document; cursor position and runtime history are never persisted.

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

See the [scene format](WSS-SCENE-FORMAT.md) for the surrounding document grammar.

## Repeatable QA

Run `swift test --filter WSSTrailTests`. Metal tests use solid alternate palettes
and check output changes, edge softness and deterministic rerendering.

Export self-generated frames and the demo parameter document:

```
AMBIENT_TRAIL_QA=/tmp/ambient-trail-qa swift test --filter WSSTrailTests
```

Three analytic paths move during t=0…1, then stop: a straight stroke, slow arc
and fast reversal. PNGs at .5/.75/1/1.25/1.5/2.1 seconds show geometry and decay.
They contain only our own procedural pixels on a neutral background. Sample
rate/lifetime begin at 32/s and 1 s; they are independently configurable.

These fixtures contain only synthetic paths and pixels. Compare geometry, width/coverage, fade and colors separately; rendering assertions do not replace manual visual review.

## Authoring

The editor adds Cursor Trail / Maustrail as a normal scene layer. Controls expose
two colors, spatial length, lifetime, full width and curve amount (see the parameter contract). Existing non-two-color or
sampleRandom configurations remain untouched until the explicit two-color action;
that undoable action uses the first and last palette stops (a single stop is duplicated).
System colors are converted explicitly to linear sRGB; palette alpha is not authored.
Lifetime edits proportionally scale both fade durations in one document mutation.

Spatial clipping walks the live sample polygon backwards from its newest sample.
At the limit it replaces the oldest retained endpoint, interpolating position,
birth time and random palette coordinate. It never adds samples. Lifetime and
length independently bound history. With maxLength absent the historical path
is unchanged, including the existing unlimited-history behavior. No `maxLength` field is materialized by
opening, selecting or saving an existing layer. Older strict readers reject the new
field when present.

New layers use length clamp(0.25*min(canvas),1,4096), width
clamp(min(canvas)/180,2,24), lifetime 1, emissionRate 32, fades 0.1/0.9,
opacity 1, edgeSoftness 0.65, seed 1 and two linear colors (0,0.7,1)/(1,0.25,0).
These concrete canvas-derived values are stored only when adding a new layer.
Total lifetime × emissionRate across all trail layers is limited to 4096; the [scene layer budget](WSS-SCENE-FORMAT.md#canvas-and-layers) also applies.

Only the shared local-pointer live preview animates trails; cursor movement does
not mutate documents. Parameter/structure changes may replace the player and clear
history while retaining playback offset. Preview sleep/display-sleep/session gates
pause the existing owner and clear history. No masks, region or blend controls.
