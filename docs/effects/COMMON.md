# Shared image-effect contracts

Model defaults describe native constructors; required JSON fields must still be supplied. Slider ranges may be narrower than valid stored ranges.

## Shared coordinates and validation

Image effects operate in logical local image units, with X right and Y down. Movement/shading angles use 0° up, 90° right, 180° down and 270° left. Layer transforms map these coordinates into the lower-left-origin canvas. Raster density does not scale speed, wavelength or displacement.

All numeric parameters must be finite; seeds are UInt32 (0…4294967295). Unknown effect types and fields fail validation, including on hidden layers or neutral stages. Image masks use normalized local UV and the [scalar decoding/sampling contract](../../WSS-SCENE-FORMAT.md#clouds-and-mask): zero leaves the incoming image unchanged, one applies the full effect. Masks do not have an independent transform. Black coverage does not authorize invalid resources.

## Ordered stacks

An image's effects array accepts arbitrary order, repetition and mixtures of Flow, Ripple and Clouds within budgets. Each active stage receives the previous stage's completed image. Array positions identify stages; equal parameters do not merge them. Layer painter order independently determines image/Rain/Trail occlusion.

Limits are 32 declared stages per image, 8 internal passes per stage, 64 declared passes per image and 256 declared passes per scene. Every current effect costs one pass. Hidden and later-elided stages still count and all their resources validate. Unsupported types fail explicitly; Rain and CursorTrail are separate layers, never entries in effects.

Stage planning uses explicit stage input/bindings. For N active stages, max(0,N−1) local offscreen passes precede final composition. Two ping-pong targets per image/in-flight slot suffice for longer stacks. Intermediate output is premultiplied with unit layer opacity and full UV; final transform/opacity/composition apply once. Neutral Flow stages may be elided. Zero-amplitude Ripple stages in longer stacks may be elided, with preserved single/two-zero-Ripple compatibility raster paths. Clouds is not newly identity-elided.

## Resource and safety limits

Intermediate targets are bounded to 256 MiB with in-flight ownership; resource
creation may fail even below nominal byte limits. These are implementation safety
ceilings, not guaranteed performance targets.

Scene manifest/canvas/layer, asset-read and decoded-image/mask ceilings belong to
the [scene asset contract](../../WSS-SCENE-FORMAT.md#asset-and-resource-boundary).
Vector/region texture limits belong to [Flow](FLOW.md); editor session/staging/working
limits to [Flow resource lifetime](../FLOW-RESOURCE-LIFETIME.md).
Rain and CursorTrail have separate layer contracts, coordinates and blend rules:
see [Rain](RAIN.md) and [Trail](../../WSS-TRAIL.md).
Playback clock, pause/resume and preview ownership belong to
[architecture](../ARCHITECTURE.md#playback-apply-and-preview).
