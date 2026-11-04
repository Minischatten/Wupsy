# Native WSS Ripple Chain v1 diagnostic

Own generated grid, markers and scalar masks, covered by the repository LICENSE.
No photographs, historical wallpaper masks, engine assets or calibrated WE values.
Regenerate with `python3 scripts/generate-wss-ripple-chain-fixture.py`;
`--check` verifies bytes without writing. Import this directory or `scene.wss.json`.

Canvas: 1920×1080 logical units; images/maps: 960×540 pixels.

| Native parameter | A: vertical waterfall area | B: broad lower basin |
|---|---|---|
| amplitude | 18 | 8 |
| wavelength | 140 | 210 |
| stretch | 3 | 1.1 |
| direction | 180° (down) | 90° (right) |
| travelSpeed | 65 | 15 |
| evolutionRate | 0.2 | 0.1 |
| seed | 17 | 981 |
| mask | assets/mask-a.png | assets/mask-b.png |

A is a narrow feathered vertical band. B is a broad feathered lower band.
Their small overlap (asset y=280…330, x=320…480) exposes ordered composition:
B samples A's completed image, rather than independently sampling the original.
Grid lines and yellow markers reveal this difference. There is one scene image
layer and two explicitly ordered effects, not a blend of two independent outputs.

`AMBIENT_RIPPLE_CHAIN_QA=/tmp/ambient-ripple-chain swift test --filter WSSRippleChainTests`
writes chain t0/1/2/4/8, A-only, B-only, A-to-B, B-to-A, both masks and overlap
crops at t2. It also measures single/chain GPU time and actual scratch allocation
at 3840×2160 and 6400×3600. All diagnostics stay under /tmp.

The accepted single-Ripple fixture remains untouched. Its limitation also remains:
soft masks over a stationary stone can distort the stone; no shoreline, coverage,
foam, wetness, collisions or fluid physics are implemented. This fixture introduces
no special handling for any image content and enables no historical wallpaper mapper.
