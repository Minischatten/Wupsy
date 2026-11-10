# Ripple

Model defaults describe native constructors; required JSON fields must still be supplied. Slider ranges may be narrower than valid stored ranges.

See [shared image coordinates, validation and stacks](COMMON.md), [scene assets and mask descriptors](../../WSS-SCENE-FORMAT.md#asset-and-resource-boundary) and [editor workflows](../EDITOR.md).

Ripple sums six seeded waves into local image displacement. It has no imported normal map and no physical shoreline or water-volume model.

| Parameter | Native default | Valid range / meaning |
|---|---:|---|
| amplitude | 6 | 0…256 local displacement units |
| wavelength | 120 | 4…8192 local units |
| stretch | 1 | 0.125…8, anisotropy along the original spatial Y axis |
| direction | 180 | [0,360), image-space movement angle |
| travelSpeed | 20 | 0…4096 local units/s |
| evolutionRate | 0.2 | 0…8, multiplier for wave evolution |
| structureRotation | 0 | [0,360), clockwise spatial rotation after stretching |
| lateralDetail | 1 | 0.125…8, transverse spatial frequency multiplier |
| seed | 1 | UInt32 |
| mask | absent | Optional scalar mask |

The seven original numeric parameters (amplitude, wavelength, stretch, direction, travelSpeed, evolutionRate and seed) are required in JSON. structureRotation defaults to zero when absent; lateralDetail defaults to one when absent. These extensions change neither the stored seed, nominal amplitude nor format version. Structure rotation changes wavevectors, not drift direction or displacement-vector weights. lateralDetail replaces only the displacement projection transverse to movement using frequency-scaled waves; it does not scale total amplitude. One preserves the original arithmetic path. It is meaningful even at zero travel speed because direction still defines the transverse axis.

Travel translates the field; evolution changes individual phases independently. With both rates zero the field is static; amplitude zero is an unwarped reference. Each complete temporal frequency is reduced independently in Double. Direction does not create perspective transport toward a viewer; use a painted Flow field for directed movement. Soft masks may distort objects inside their transition: there is no shoreline detection, foam, wetness or water compositing.

## JSON contract

An image layer may contain a native Ripple stage:

```json
[{"type":"ripple", "amplitude":12, "wavelength":180, "stretch":1.6,
  "direction":180, "travelSpeed":35, "evolutionRate":0.35, "seed":7319,
  "mask":"assets/mask.png"}]
```

`mask` is optional; absent/null means full coverage. See the shared
[image-mask semantics](COMMON.md#shared-coordinates-and-validation) and
[safe paths, scalar decoding and descriptor spelling](../../WSS-SCENE-FORMAT.md#clouds-and-mask).
Unknown fields, missing files, symlinks and nonfinite/out-of-range numbers fail.
Mixed/repeated stages follow the shared stack contract; older strict readers
may reject capabilities they do not recognize.

## Authoring

The inspector exposes amplitude, wavelength, stretch, movement direction/speed,
evolution, structure rotation, lateral detail and seed. Structure rotation controls
the pattern; lateral detail controls displacement transverse to movement.
Neither is a camera-perspective control.
