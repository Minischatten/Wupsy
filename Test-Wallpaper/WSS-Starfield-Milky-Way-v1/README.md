# Native Milky Way acceptance scene

Original synthetic Wupsy fixture under repository LICENSE. The foreground is the
unchanged schematic silhouette generated for WSS-Starfield-v1 by
scripts/generate-wss-starfield-fixture.py, copied here for a self-contained project.
No external image, shader or personal media. The Milky Way uses no image asset.

Import this directory or scene.wss.json: black 4K canvas, static stars and Milky Way,
then a transparent foreground. The figure must occlude stars and the galactic band.
Product default is Milky Way OFF; this scene enables it for review.

Inspect fine cloud/grain detail, dark dust, soft band edges and subtle color.
Try angles 0/30/90/135 and both wide and tall regions. Move the center (0…1), vary
width, intensity, structure/dust strength and seed. Test unrestricted RGB colors.
Enable small X/Y star drift and inspect all wrap boundaries; the band should move
with the stars, while shooting-star motion remains independent. Turn all animation
off for a static scene. Check 24/30/60 FPS, Standard/HiDPI and 4K; several layers;
Hide/Show; Save/Reopen; Undo/Redo and separate star/Milky Way color transactions.
The editing canvas remains image-only plus the existing rectangle handles.

The band is a periodic galactic field, not an astronomical sky model. A complete
travel cycle repeats. The appearance and GPU cost need manual review on target
hardware, especially with multiple wide active regions.

For the optical revision, compare identical seed/parameters at intensity 0.45 and
0.12 using WSSMilkyWayVisualComparisonTests and WUPSY_MILKY_COMPARISON. The old
shader is retained only in test code. Review local bright clumps, weak/partly
interrupted regions, fine stars tied to density and broad soft dust absorption.
Normal stars and shooting stars must retain their original distribution.
