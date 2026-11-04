# WSS Clouds v1 — Evening Sky

Native visual test scene for the existing WSS Clouds v1 effect. Import this folder
in Wupsy, select it and set it as wallpaper. It runs directly in WSS.

Both PNGs are project-owned, generated solely from colors and geometry by
`scripts/generate-wss-clouds-fixture.py` (repository root). No external images,
fonts or Wallpaper Engine resources are used. Assets use the repository license.

Clouds should drift **left to right, slightly upward**. The mask is full white
(255 = full configured effect) in the upper sky, fades smoothly toward the horizon,
and is black (0 = no effect) in the lower area. The bottom remains static.

Parameters: velocity `[24, -3]`, scale `600`, intensity `0.45`, density `0.5`, seed `7`.
