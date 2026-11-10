# Clouds

Model defaults describe native constructors; required JSON fields must still be supplied. Slider ranges may be narrower than valid stored ranges.

See [shared image coordinates, validation and stacks](COMMON.md), [scene assets and mask descriptors](../../WSS-SCENE-FORMAT.md#asset-and-resource-boundary) and [editor workflows](../EDITOR.md).

Clouds generates its own seeded periodic scalar noise; it uses no external noise texture. The primary field combines shape, interior and finer detail at distinct frequencies, rather than averaging identical octaves. Optional secondary noise has its own velocity, scale and orientation.

| Parameter | Native default | Valid range / meaning |
|---|---:|---|
| velocity | [12, 0] | Each component −4096…4096 local units/s |
| scale | 256 | 1…8192 local units per repeated tile; larger means larger structures |
| intensity | 0.3 | 0…1, effect intensity |
| density | 0.5 | 0…1, cloud coverage distribution |
| seed | 1 | UInt32 |
| mask | absent | Optional scalar mask |
| secondaryField | absent | Optional velocity/scale pair, same bounds as primary |
| secondaryInfluence | 0.35 | 0…1; zero disables secondary contribution |
| softness | 0 | 0…1; broader, more diffuse structure toward one |
| brightness | 1 | 0…2; tone gain, not opacity |
| shadingAmount | 0 | 0…1; zero is unshaded |
| shadingDirection | 0 | [0,360) degrees |

An absent secondary field stays absent on opening or editing unrelated controls. Opening existing unmasked Clouds does not add a mask or secondary field. The current editor exposes primary velocity/scale, intensity/density/brightness, and secondary X/Y velocity only when a secondary field already exists; secondary scale/influence, softness, shading and seed are retained document parameters, not independently editable inspector sliders. New Clouds adds a private black mask; paint that mask or explicitly choose Full Image before expecting visible clouds. The model default of no mask applies to constructor/JSON semantics, not that Add action.

Softness changes structure, not size, opacity or brightness. Brightness uses SDR clamping: zero makes cloud tone black, one preserves unshaded white, and values up to two can brighten shaded tones without exceeding white. Tone does not change alpha/coverage. Independent domains reduce their phases in Double before GPU upload, avoiding discontinuities from sharing an incorrectly wrapped phase between noninteger frequencies. The primary lattice spacing is scale/8 before finer detail. The noise lattice is 8×8, interpolated into a 128×128 R8 texture; secondary domains share seeded data but use distinct sampling transforms. No fluid simulation or physical lighting is implied.

## Coverage and tone arithmetic

For softness s, retained detail r=1−s. With body/middle/fine noise samples b,m,f, field starts as clamp(b+(m−0.5)×0.30×r+(f−0.5)×0.08×r²,0,1). At s=0 this is the base structured path. Active secondary detail d adds influence×0.55×(1−0.5s)×(d−0.5), clamped again. The shape threshold is 1.15−1.3×density+0.38s×(1−2×density), with smoothstep half-width 0.12+0.38s. Interior starts at mix(0.55+0.30m+0.15f,1,0.85s), then mixes toward one using smoothstep(0.8,1,density). Coverage is shape×interior; amount is coverage×intensity×mask. Density endpoints remain empty/full configured effect, independent of softness.

Directional shading uses bounded symmetric noise differences, not geometric normals. With shading amount a and the combined directional slope q, tone is clamp((1−0.45a+0.65a×clamp(4q,−1,1))×brightness,0,1); when shading is disabled tone is clamped brightness. The incoming premultiplied RGB mixes toward alpha×tone; incoming alpha is unchanged before ordinary layer composition. Base/extended/soft paths preserve the zero-extension behavior. Exact noise coordinates, offsets and shader selection live in [the implementation](../../Sources/Wupsy/WSSCloudsResources.swift), with parameter/time construction in [the native model](../../Sources/Wupsy/WSSImageEffect.swift).

## JSON contract

An image layer's optional `effects` can contain:

```json
[
  {
    "type": "clouds",
    "velocity": [12, -3],
    "scale": 600,
    "intensity": 0.3,
    "density": 0.5,
    "seed": 7,
    "mask": "assets/mask.png"
  }
]
```

The base fields `velocity` and `scale`, plus `intensity`, `density` and `seed`,
remain required for the velocity/scale spelling. They map directly to native values without
an import adapter. Alternatively replace BOTH base fields with `primaryField`:

```json
{
  "type": "clouds",
  "primaryField": {"velocity": [18, -2], "scale": 1600},
  "secondaryField": {"velocity": [-12, 8], "scale": 700},
  "secondaryInfluence": 0.4,
  "intensity": 0.65,
  "density": 0.55,
  "brightness": 1,
  "shadingAmount": 0.6,
  "shadingDirection": 45,
  "seed": 17,
  "mask": "assets/mask.png"
}
```

Specifying `primaryField` together with top-level velocity/scale is an error. Each
field requires exactly velocity and scale. Bounds and native defaults are in the
parameter table above; optional extension fields retain those defaults when absent.
Null (except the optional mask), unknown fields and incomplete nested fields are rejected.
Old JSON selects the exact original v1 pipeline; no format version bump, engine defaults
or fingerprints are involved. A zero softness preserves the exact existing structured
v1/v2 look and shader paths; this is an additive v1 extension with no engine default.
At softness one, transitions are broader and diffuse with less fine fragmentation;
scale remains the independent size control.
Density endpoints, masking, independent field motion and alpha remain intact.
See the fully procedural [Clouds Storm example](../../Test-Wallpaper/WSS-Clouds-Storm/).
