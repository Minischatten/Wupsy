# Native image effects

Wupsy supports Flow, Ripple and Clouds on image layers, plus separate Rain and [CursorTrail](WSS-TRAIL.md) layers. This reference describes the current native implementation. It does not define import profiles or emulate an external wallpaper runtime.

See [scene format](WSS-SCENE-FORMAT.md) for required JSON fields and resource descriptors, and [editor guide](docs/EDITOR.md) for authoring. Model defaults below describe native constructors; required JSON fields must still be supplied. Slider ranges may be narrower than valid stored ranges.

## Shared coordinates and validation

Image effects operate in logical local image units, with X right and Y down. Movement/shading angles use 0° up, 90° right, 180° down and 270° left. Layer transforms map these coordinates into the lower-left-origin canvas. Raster density does not scale speed, wavelength or displacement.

All numeric parameters must be finite; seeds are UInt32 (0…4294967295). Unknown effect types and fields fail validation, including on hidden layers or neutral stages. Image masks use linear red intensity, normalized local UV and clamp sampling: zero leaves the incoming image unchanged, one applies the full effect. Masks do not have an independent transform. Black coverage does not authorize invalid resources.

## Clouds

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

JSON accepts either velocity plus scale, or primaryField containing both; mixing spellings is invalid. intensity, density and seed are required. Optional extension fields retain their defaults when absent. An absent secondary field stays absent on opening or editing unrelated controls. The current editor exposes primary velocity/scale, intensity/density/brightness, and secondary X/Y velocity only when a secondary field already exists; secondary scale/influence, softness, shading and seed are retained document parameters, not independently editable inspector sliders. New Clouds adds a private black mask; paint that mask or explicitly choose Full Image before expecting visible clouds. The model default of no mask applies to constructor/JSON semantics, not that Add action.

Softness changes structure, not size or opacity. Brightness uses SDR clamping: zero makes cloud tone black, one preserves unshaded white, and values up to two can brighten shaded tones without exceeding white. Tone does not change alpha/coverage. Independent domains reduce their phases in Double before GPU upload, avoiding discontinuities from sharing an incorrectly wrapped phase between noninteger frequencies. The noise lattice is 8×8, interpolated into a 128×128 R8 texture; secondary domains share seeded data but use distinct sampling transforms. No fluid simulation or physical lighting is implied.

### Coverage and tone arithmetic

For softness s, retained detail r=1−s. With body/middle/fine noise samples b,m,f, field starts as clamp(b+(m−0.5)×0.30×r+(f−0.5)×0.08×r²,0,1). At s=0 this is the base structured path. Active secondary detail d adds influence×0.55×(1−0.5s)×(d−0.5), clamped again. The shape threshold is 1.15−1.3×density+0.38s×(1−2×density), with smoothstep half-width 0.12+0.38s. Interior starts at mix(0.55+0.30m+0.15f,1,0.85s), then mixes toward one using smoothstep(0.8,1,density). Coverage is shape×interior; amount is coverage×intensity×mask. Density endpoints remain empty/full configured effect, independent of softness.

Directional shading uses bounded symmetric noise differences, not geometric normals. With shading amount a and the combined directional slope q, tone is clamp((1−0.45a+0.65a×clamp(4q,−1,1))×brightness,0,1); when shading is disabled tone is clamped brightness. The incoming premultiplied RGB mixes toward alpha×tone; incoming alpha is unchanged before ordinary layer composition. Base/extended/soft paths preserve the zero-extension behavior. Exact noise coordinates, offsets and shader selection live in [the implementation](Sources/Wupsy/WSSCloudsResources.swift), with parameter/time construction in [the native model](Sources/Wupsy/WSSImageEffect.swift).

## Rain

Rain is a procedural layer in painter order, not an image effect. A rectangular region in lower-left canvas coordinates determines density and clipping. Direction 0° is **down** for Rain: velocity = speed × (sin(angle), −cos(angle)) in canvas coordinates. This differs from image-effect angles because image Y points downward.

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

A region has positive dimensions ≤8192 per axis and ≤32 Mi square units; origin magnitudes are ≤1,000,000. It may extend beyond the canvas. Nominal count is round(density × region area / 1,000,000). A padded direction-aligned domain adds edge instances. The combined scene limit is **8192 instances**, including margins and hidden Rain layers; excess is an error. Zero nominal density produces no instances.

SplitMix64 supplies separate layout, length and profile streams. Identical scene inputs and time reproduce the population; no per-frame random draws occur. See [the exact random contract](docs/RAIN-RANDOM.md). Count and seed do not depend on Standard/HiDPI rendering.

Streaks are analytic neutral white, with depth-dependent size/speed, not imported textures. Optional masks cover the region in normalized UV, with texture top at region top. sourceOver uses premultiplied S.rgb + D.rgb×(1−S.a); additive uses S.rgb + D.rgb. Both use S.a + D.a×(1−S.a) for alpha. Place Rain between background and foreground images for occlusion. No collisions, refraction, physical rain or external photometry equivalence is promised.

## Ripple

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

The seven original numeric parameters through seed are required in JSON. structureRotation defaults to zero; lateralDetail defaults to one. Structure rotation changes wavevectors, not drift direction or displacement-vector weights. lateralDetail replaces only the displacement projection transverse to movement using frequency-scaled waves; it does not scale total amplitude. One preserves the original arithmetic path. It is meaningful even at zero travel speed because direction still defines the transverse axis.

Travel translates the field; evolution changes individual phases independently. With both rates zero the field is static; amplitude zero is an unwarped reference. Each complete temporal frequency is reduced independently in Double. Direction does not create perspective transport toward a viewer; use a painted Flow field for directed movement. Soft masks may distort objects inside their transition: there is no shoreline detection, foam, wetness or water compositing.

## Flow

Flow performs bounded image transport along a local vector field. Three overlapping age windows blend finite source samples. It is not unlimited advection, frame feedback or fluid simulation; crossfades can soften or duplicate image details.

| Parameter | Native / decoder default | Valid range / meaning |
|---|---:|---|
| flowMap | required | PNG or native field descriptor |
| speed | 40 | 0…1024 local units/s |
| strength | 12 | 0…128 local half-excursion for a unit vector |
| edgeProtectionPixels | 0 | 0…4096 local units |
| edgeProtectionMode | imageBounds | imageBounds or region |
| flowRegion | absent | Required exactly when mode is region |

Speed zero, strength zero or an effectively neutral field makes Flow inactive. Otherwise period T=2×strength/speed. Field magnitude scales speed and excursion; the period is unchanged. Vectors are sampled bilinearly without normalization; component bounds are [−1,1], so diagonal magnitude can reach √2. Coverage is a separate blend weight, not a velocity multiplier or confidence value.

### Vector fields and storage

flowMap is {format, version:1, asset}. Supported formats:

- wss-flow-rgba8: PNG with R/G signed components, reserved B=0, A coverage. Component b maps to (b−128)/128 below 128, otherwise (b−128)/127. 128 is exact zero. Components are decoded before bilinear filtering; coverage is independently sampled. Not a color image or extracted engine texture.
- wss-vector-field-f16: .wssvf with 32-byte header: magic WSSVF16 plus NUL, then six little-endian UInt32 values (version=1, width, height, coverageWidth, coverageHeight, reserved=0). Payload is interleaved little-endian Float16 X/Y, followed by optional R8 coverage. Coverage is absent when both dimensions are zero, otherwise exactly matches the vector dimensions. Exact lengths, finite bounded components and reserved/version values are validated. Signed zero and covered-out vectors are preserved; neutrality is derived, not trusted metadata.

Fields have dimensions 1…8192 and at most floor(32 MiB/5) pixels. The file payload and allocated aggregate vector/coverage/white textures are separately bounded. The .wssvf header adds 32 bytes to the payload allowance. No automatic resampling occurs when editing an existing field or replacing its image.

### Regions, coverage and edges

A region descriptor is {format:"wss-flow-region-r8", version:1, asset:"assets/area.wssregion"}. The 20-byte header contains WSSREG1 plus NUL, then LE UInt32 version, width and height. Exactly width×height binary bytes (0 or 255) follow. Dimensions are 1…2048; payload ≤4 MiB. Region membership is separate from direction/magnitude and continuous coverage.

imageBounds mode forbids a flowRegion. With edge width N=0 there is no edge multiplier. For N>0, coverage is multiplied by smoothstep(N/2+0.5,N+0.5,e), where e is the nearest local image-edge distance. No field/coverage data is rewritten.

region mode requires a region. Blend amount is coverage × regionGate × edgeFactor. edgeFactor is one for N=0, otherwise smoothstep(0,N,max(0,distance)). Region boundaries include islands, holes and image edges; outside the image is inactive. Signed distances are computed from binary cell boundaries, sampled bilinearly between centers, and are approximate near corners. The region gate itself uses the responsible binary cell. Distance data is a derived cache, not persisted project content.

The editor adds Flow with private neutral .wssvf data, no coverage, an empty private region, speed 40, strength 12 and N=0. Field axes are floor-scaled to a maximum longest axis of 512 (minimum one); region axes are ceiling-scaled to a maximum longest axis of 2048. Both use local image size, not viewport size. Existing imageBounds projects remain imageBounds until an explicit supported edit changes them; loading does not invent regions.

Direction painting activates region cells; Neutralize reduces vectors while retaining membership; Option/Erase removes region membership and zeroes affected vectors. Coverage bytes are preserved. Field and region changes are one atomic Undo operation. Overlay and live preview use the same selected provisional state; no brush history or overlay is serialized.

## Ordered stacks

An image's effects array accepts arbitrary order, repetition and mixtures of Flow, Ripple and Clouds within budgets. Each active stage receives the previous stage's completed image. Array positions identify stages; equal parameters do not merge them. Layer painter order independently determines image/Rain/Trail occlusion.

Limits are 32 declared stages per image, 8 internal passes per stage, 64 declared passes per image and 256 declared passes per scene. Every current effect costs one pass. Hidden and later-elided stages still count and all their resources validate.

For N active stages, max(0,N−1) local offscreen passes precede final composition. Two ping-pong targets per image/in-flight slot suffice for longer stacks. Intermediate output is premultiplied with unit layer opacity and full UV; final transform/opacity/composition apply once. Neutral Flow stages may be elided. Zero-amplitude Ripple stages in longer stacks may be elided, with preserved single/two-zero-Ripple compatibility raster paths. Clouds is not newly identity-elided.

## Resource and safety limits

- Manifest ≤2 MiB; canvas ≤8192 per axis / 32 Mi pixels; 1…128 scene layers.
- Native image reads ≤128 MiB per asset; decoded source image dimensions ≤8192 per axis / 32 Mi pixels. The base decoded-image accounting limit is 128 MiB and includes allocated field/region/Rain texture contributions.
- Scalar mask, aggregate vector-field textures and region/distance textures have separate 32-MiB limits in their resource owners. Region distance cache is bounded to 32 MiB.
- Intermediate targets are bounded to 256 MiB with in-flight ownership; resource creation may fail even below nominal byte limits.
- Vector/region session generations share a 128-MiB budget; editor total staging is 512 MiB. Paint/region-distance working allocations are bounded to 128 MiB. Resource validation/preflight must succeed before model adoption.
- Paths are project-relative, with no traversal, absolute/tilde paths or symlink escapes. Project imports also reject special files. Hidden/neutral effects do not bypass validation. See [asset contracts](WSS-SCENE-FORMAT.md#asset-and-resource-boundary).

These are implementation safety ceilings, not guaranteed performance targets. Pause/resume uses an explicit elapsed playback clock; editor live preview and desktop share the native runtime. Static Edit Canvas deliberately omits effects, Rain and Trail.
