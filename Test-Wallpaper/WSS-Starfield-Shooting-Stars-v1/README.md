# Native Starfield shooting-star acceptance scene

Original synthetic, asset-free Wupsy fixture under repository LICENSE. No photos,
external shaders or downloaded assets. Import scene.wss.json or this directory.

A static 4K starfield has shooting stars enabled at 60 per ten minutes (six/minute) for easier review
(the product default is disabled, 20 per ten minutes when enabled). Wait up to ten seconds
for the first meteor; later intervals vary. Try lower frequency for a quiet sky.

Review head/tail, gentle appearance and fade, speed/direction/variation, and a zero
length head-only meteor. Change the base RGB and verify inherited color. Drift
must move only background stars. Resize/move the frame and inspect all boundaries.
Add a transparent synthetic foreground or use the existing Starfield-v1 scene to
check occlusion; no additional mask is required. Check multiple seeds/layers,
24/30/60 FPS, Standard/HiDPI, Pause/Resume, Undo/Redo and Save/Reopen.

Turn off shooting stars, twinkling and both drift axes to return to a static layer.
The editing canvas remains image-only with a position frame; use Live Preview for
actual stars and meteors. No user media or local library data is used here.
