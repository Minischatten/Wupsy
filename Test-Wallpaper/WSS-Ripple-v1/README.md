# Native WSS Ripple v1 diagnostic

All images are independently generated geometry/colors, covered by the repository
LICENSE. No input photographs, engine assets, normal maps or downloaded media.
Reproduce with `python3 scripts/generate-wss-ripple-fixture.py`; `--check` compares
bytes without writing. Import this directory or `scene.wss.json`, then use WSS effects.

The 1920×1080 logical canvas uses 960×540 PNGs. Fixed parameters:

| Parameter | Value |
|---|---|
| amplitude | 12 logical local image units |
| wavelength | 180 logical local image units |
| stretch | 1.6 (elongates structure along local y) |
| direction | 180°: visible downward drift |
| travelSpeed | 35 logical units/second |
| evolutionRate | 0.35 cycles/second multiplier |
| seed | 7319 |
| mask | assets/mask.png, linear red |

Grid spacing, fine lines and yellow points reveal displacement. The left part of
the upper water boundary is hard; its right part is a soft ramp. Side/bottom
margins are zero-mask references. The artificial stone has a stationary center;
a soft ramp extends inside its rim. The edge moves inward/outward through ordinary
image distortion only. There is no shoreline detector, fluid volume, foam,
wetness or water compositing. This can suggest a small arriving/receding wave,
but does not simulate water covering a rock.

For diagnostic variants set evolutionRate=0 (pure translation), travelSpeed=0
(pure evolution), or both=0 (static field). amplitude=0 is the exact unwarped
reference. Direction is 0 up, 90 right, 180 down, 270 left in image space.

`AMBIENT_RIPPLE_QA=/tmp/ambient-ripple swift test --filter WSSRippleTests` writes
frames at t0/1/2/4/8, stone crops, mask, direction/motion variants and benchmarks
at 3840×2160 and 6400×3600. Diagnostic outputs stay outside this fixture.
