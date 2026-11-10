# Flow

Model defaults describe native constructors; required JSON fields must still be supplied. Slider ranges may be narrower than valid stored ranges.

See [shared image coordinates, validation and stacks](COMMON.md), [scene assets and mask descriptors](../../WSS-SCENE-FORMAT.md#asset-and-resource-boundary) and [editor workflows](../EDITOR.md).

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

Aggregate vector/coverage/white textures have a separate 32-MiB limit. Fields have dimensions 1…8192 and at most floor(32 MiB/5) pixels. The file payload and allocated aggregate vector/coverage/white textures are separately bounded. The .wssvf header adds 32 bytes to the payload allowance. No automatic resampling occurs when editing an existing field or replacing its image.

### Regions, coverage and edges

A region descriptor is {format:"wss-flow-region-r8", version:1, asset:"assets/area.wssregion"}. The 20-byte header contains WSSREG1 plus NUL, then LE UInt32 version, width and height. Exactly width×height binary bytes (0 or 255) follow. Dimensions are 1…2048; payload ≤4 MiB. Region membership is separate from direction/magnitude and continuous coverage. Region/distance textures have a separate 32-MiB resource-owner limit; the region distance cache is also bounded to 32 MiB.

imageBounds mode forbids a flowRegion. With edge width N=0 there is no edge multiplier. For N>0, coverage is multiplied by smoothstep(N/2+0.5,N+0.5,e), where e is the nearest local image-edge distance. No field/coverage data is rewritten.

region mode requires a region. Blend amount is coverage × regionGate × edgeFactor. edgeFactor is one for N=0, otherwise smoothstep(0,N,max(0,distance)). Region boundaries include islands, holes and image edges; outside the image is inactive. Signed distances are computed from binary cell boundaries, sampled bilinearly between centers, and are approximate near corners. The region gate itself uses the responsible binary cell. Distance data is a derived cache, not persisted project content.

The editor adds Flow with private neutral .wssvf data, no coverage, an empty private region, speed 40, strength 12 and N=0. Field axes are floor-scaled to a maximum longest axis of 512 (minimum one); region axes are ceiling-scaled to a maximum longest axis of 2048. Both use local image size, not viewport size. Existing imageBounds projects remain imageBounds until an explicit supported edit changes them; loading does not invent regions.

Direction painting activates region cells; Neutralize reduces vectors while retaining membership; Option/Erase removes region membership and zeroes affected vectors. Coverage bytes are preserved and are not painted by the direction brush. Field and region changes are one atomic Undo operation. Overlay and live preview use the same selected provisional state; no brush history or overlay is serialized.

## JSON contract

A Flow stage requires a `flowMap` descriptor. Optional fields use the native/decoder
defaults in the table above. All field and region formats described here are version 1.

```json
{"type":"flow","flowMap":{"format":"wss-vector-field-f16","version":1,"asset":"assets/field.wssvf"},"speed":40,"strength":12}
```

## Session ownership and admission

See [Flow resource lifetime](../FLOW-RESOURCE-LIFETIME.md) for immutable generations,
session/staging/working budgets, directional Undo policy and atomic adoption.
Field/region GPU texture limits are specified above; aggregate decoded-image accounting
is in the [scene asset contract](../../WSS-SCENE-FORMAT.md#asset-and-resource-boundary).
