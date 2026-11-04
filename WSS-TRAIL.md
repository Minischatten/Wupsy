# Native WSS cursor trail

The native, texture-free cursorTrail layer is editable in Wupsy. Its mathematical geometry and historical provenance limits are described in [the curve contract](docs/CURSOR-TRAIL-CURVES.md). No reference images, video pixels, captured pointer tracks or external curve implementation are included.

## Parameter contract

`WSSTrailConfiguration` is a Codable value DTO, validated before simulation.
It is saved as JSON and edited without making the value model depend on Metal.
It is used directly by the cursorTrail scene-layer grammar.

| Field | Meaning |
|---|---|
| colors | 1–16 explicit linear RGB colors, components 0…1; uniformly spaced palette stops |
| colorMode | sampleRandom: seeded scalar per emitted point, linearly sampled palette; ageGradient: palette sampled at age/lifetime |
| width | full geometric ribbon width in logical canvas pixels; 0 < width ≤ 256 |
| curveSmoothing | optional on input; finite 0…0.5, absent defaults to 0.15; UI: Kurvenauslenkung / Curve amount; reset to 0.15 |
| maxLength | optional spatial history limit, >0…16384 logical canvas pixels; absent means unlimited; null rejected |
| lifetime | seconds, 0 < lifetime ≤ 10 |
| emissionRate | samples per active second, 1…512; lifetime × rate ≤ 4096 |
| fadeIn / fadeOut | seconds; nonnegative, sum ≤ lifetime; linear ramps with plateau if any |
| opacity | 0…1; multiplied by age envelope and cross-section coverage |
| edgeSoftness | 0…1; inward smoothstep edge width as fraction of ribbon half-width; derivative antialiasing remains at zero |
| seed | UInt32, deterministic palette randomization |

All fields except absent `maxLength` are encoded explicitly, including `curveSmoothing`.
Old projects missing `curveSmoothing` load cleanly at 0.15; explicit null rejects. Decode then validate (or construct the validated
simulation). Unknown JSON fields and null values are rejected by the native document validator.
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

Each connection uses a cubic Bezier derived from endpoint and neighbor-tangent
conditions, with five subdivisions. `curveSmoothing` scales its control arms;
0 keeps the centerline on the chord, larger values may overshoot. The default 0.15
preserves accepted vertex geometry; it is not a historical claim about how that
number was originally selected. Normals, full width, RGBA interpolation and triangle
order are unchanged. The geometry helper knows no ages or opacity values.
Metal computes smooth transverse coverage analytically and blends SourceAlpha/One
RGB, preserving destination alpha. There is no texture lookup, extracted texture
profile, bloom or offscreen blur. Age-based alpha remains unchanged and independent
of curve amount, as do lifetime, emission, stillness and pointer-loss behavior.
CPU tessellation and a fresh vertex buffer per draw are the accepted initial
implementation; commands retain their own buffers through GPU completion.

Coordinates use logical canvas pixels with upward Y; caller supplies a matching
viewport. The live player uses SceneCursor cover-crop conversion; deterministic tests
supply explicit positions and do not poll the real mouse.

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
two colors, spatial length, lifetime, full width and curve amount (0…0.50, default/reset 0.15). Existing non-two-color or
sampleRandom configurations remain untouched until the explicit two-color action;
that action uses the first and last palette stops (a single stop is duplicated).
System colors are converted explicitly to linear sRGB; palette alpha is not authored.
Lifetime edits proportionally scale both fade durations in one document mutation.

Spatial clipping walks the live sample polygon backwards from its newest sample.
At the limit it replaces the oldest retained endpoint, interpolating position,
birth time and random palette coordinate. It never adds samples. Lifetime and
length independently bound history. With maxLength absent the historical path
is unchanged, including the existing unlimited-history behavior. No field is materialized by
opening, selecting or saving an existing layer. Older strict readers reject the new
field when present.

New layers use length clamp(0.25*min(canvas),1,4096), width
clamp(min(canvas)/180,2,24), lifetime 1, emissionRate 32, fades 0.1/0.9,
opacity 1, edgeSoftness 0.65, seed 1 and two linear colors (0,0.7,1)/(1,0.25,0).
These concrete canvas-derived values are stored only when adding a new layer.
The existing per-scene 4096 lifetime*rate budget is unchanged.

Only the shared local-pointer live preview animates trails; cursor movement does
not mutate documents. Parameter/structure changes may replace the player and clear
history while retaining playback offset. Preview sleep/display-sleep/session gates
pause the existing owner and clear history. No masks, region or blend controls.
