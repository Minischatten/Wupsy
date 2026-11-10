# Rain

Model defaults describe native constructors; required JSON fields must still be supplied. Slider ranges may be narrower than valid stored ranges.

Rain is a procedural layer in painter order, not an image effect. A rectangular region in lower-left canvas coordinates determines density and clipping. Direction is 0° down, 90° right, 180° up and 270° left for Rain; out-of-range angles are rejected, not wrapped: velocity = speed × (sin(angle), −cos(angle)) in canvas coordinates. This differs from image-effect angles because image Y points downward.

| Parameter | Native default | Valid range / meaning |
|---|---:|---|
| direction | 0 | [0,360) degrees |
| speed | 900 | 0…6000 logical units/s |
| density | 100 | 0…2000 drops per million logical square units |
| length | 32 | 0.5…256 logical units before depth/class scaling |
| width | 1.2 | 0.25…8 full logical units before depth scaling |
| opacity | min 0.08, max 0.24 | 0…1, min ≤ max |
| seed | 1 | UInt32 |
| profiles | absent | When present, exactly three length/width objects |

Profile lengths are 0.25…384 and widths 0.25…8. Without profiles, independent 0.5/1/1.5 length classes vary the base length. With profiles, the selected profile supplies length and width together, replacing those base geometry choices. Eight depth groups vary length, width and speed; depth scales are 0.69375…1.30625. The editor adds new Rain with three profiles (24,1.2), (40,1.6), (56,2.0) and density 150; this differs from the model constructor density 100 in the table. For exceptionally small canvases the Add action raises density only enough to avoid a rounded zero count, subject to the 2000 limit. Existing profile-less scenes stay profile-less until an explicit profile action; loading does not materialize profiles. No user-project density has been adopted as a new global default.

A region is an axis-aligned rectangle with positive dimensions ≤8192 per axis and ≤32 Mi square units; origin magnitudes are ≤1,000,000. It may extend beyond the canvas: generation and density use the entire region, fragment clipping uses its rectangle, and normal canvas projection crops the output. No implicit repositioning or clamping. Nominal count is round(density × region area / 1,000,000). A padded direction-aligned domain adds edge instances. The combined scene limit is **8192 instances**, including margins and hidden Rain layers; excess is an error. A rounded nominal count of zero generates no instances (including zero density).

SplitMix64 supplies separate layout, length and profile streams. Identical scene inputs and time reproduce the population; no per-frame random draws occur. See [the exact random contract](../RAIN-RANDOM.md). Count and seed do not depend on Standard/HiDPI rendering, backing resolution or drawable resize.

Streaks are analytic neutral white, with depth-dependent size/speed, not imported textures. Streak output is premultiplied neutral RGB/alpha. Optional masks cover the entire region in normalized UV, with texture top at region top, independent of layer order. Absent means full coverage inside the region; black suppresses Rain and white preserves it. Mask assets participate in normal referenced-resource, save and validation paths. sourceOver (the default) uses S.rgb + D.rgb×(1−S.a); additive uses S.rgb + D.rgb. Both use S.a + D.a×(1−S.a) for alpha; UNorm output clamps at its storage range. Array position determines occlusion: place Rain between background and foreground images, or after both for foreground Rain. Multiple Rain layers use the same ordering. No collisions, refraction, physical rain or external photometry equivalence is promised.

## JSON contract

An explicit `type: "rain"` has required `region` and `rain`, optional `visible`
(true), optional `composition` (`sourceOver`) and optional `mask`.
Unknown layer types/fields remain errors. Older readers reject Rain instead of
silently omitting it. No document migration.

```json
{
  "type": "rain",
  "region": { "x": 0, "y": 0, "width": 1920, "height": 1080 },
  "composition": "sourceOver",
  "rain": {
    "direction": 0, "speed": 900, "density": 100,
    "length": 32, "width": 1.2,
    "opacity": { "min": 0.08, "max": 0.24 }, "seed": 1
  }
}
```

All seven base Rain settings and all four region fields are required, even when
profiles supply geometry. All numeric parameters must be finite; seed is UInt32
(0…4294967295). Parameter bounds and constructor defaults are in the table above;
there is no color parameter. Optional `rain.profiles`, when present, contains exactly
three objects with required finite `length` and `width` in the bounds above.
Open/display/save do not add profiles. This is an additive v1 extension;
older strict readers reject unknown fields.

The optional layer-level `mask` uses the native image descriptor; see
[descriptor, scalar decoding and path contracts](../../WSS-SCENE-FORMAT.md#asset-and-resource-boundary).
Rain has no image/effects fields; only an explicit mask adds an asset dependency.
Scene-wide asset budgets are in the [scene format](../../WSS-SCENE-FORMAT.md#asset-and-resource-boundary);
playback time and preview ownership are in [architecture](../ARCHITECTURE.md#playback-apply-and-preview).
