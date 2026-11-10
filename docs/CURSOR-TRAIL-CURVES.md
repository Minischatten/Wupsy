# CursorTrail curves

## Mathematical requirements

For a connection from P to Q, use the previous observation A and following
observation D to estimate directions across each endpoint. Missing neighbors
repeat the nearest endpoint. Let k be the dimensionless control-arm amount.
Require a cubic with endpoints P,Q and endpoint derivatives 3*k*(Q-A) and
3*k*(D-P). Converting those derivative conditions to Bezier control points gives:

- B0=P; B1=P+k*(Q-A); B2=Q+k*(P-D); B3=Q.
- B(t)=(1-t)^3 B0 + 3*(1-t)^2*t B1 + 3*(1-t)*t^2 B2 + t^3 B3.

For a shared interior endpoint both neighboring connections have the same
endpoint derivative, giving parametric C1 continuity when their t intervals have
equal duration. This is a uniform neighbor-tangent spline, not a denoising filter,
arc-length parameterization or centripetal spline. No time-based resampling is added.
At k=0 the centerline stays on each straight chord (with smoothstep parameter speed).
Larger k extends the handles and can overshoot at corners/reversals; k=0.5 is not a
promise of greater smoothness or less wobble. Full coincidence is finite and
stationary neighborhoods draw no ribbon. Duplicate points are not removed.

At k=0.15 each control arm is 15% of its neighbor secant and the endpoint
derivative is 0.45 times that secant. In the uniform cardinal convention
T=(1-tension)*(Q-A)/2, k=(1-tension)/6: k=1/6 gives uniform Catmull-Rom,
whereas k=0.15 corresponds to tension 0.1. Our UI exposes k directly, not that
inversely related conventional tension.

The UI exposes handle reach directly as **Kurvenauslenkung / Curve amount**,
rather than temporal filtering. The JSON parameter, range/default, reset and
strict-reader/encoding compatibility belong to the
[Trail parameter contract](../WSS-TRAIL.md#parameter-contract).

Five equal t subdivisions remain per connection, with two triangles per subdivision.
This gives up to 30 triangle vertices per connection and controls polygonal
approximation/cost, not lifetime or fading. Ribbon normals
remain the normalized perpendiculars of Q-A and D-P, linearly interpolated at t;
zero directions yield zero normals. Width and triangle order remain unchanged.
The evaluator uses Bernstein arithmetic in the same Float operation order as the
accepted default, chosen expressly to preserve its rendered positions.

## Time and appearance are separate

Sampling rate, epoch, history clipping, lifetime, width, opacity, palette, seeded
colors and stop/reset rules are unchanged. Alpha at a sample is opacity times the
minimum of the existing entrance/exit ramps. Color and alpha interpolate between
samples on the ribbon. `edgeSoftness` controls transverse coverage in the shader;
it is neither k nor a lifetime parameter. The curve helper receives positions and
k only, never ages or alpha. A changed curve can redistribute visible pixels, but
cannot change sample expiry, timing, configured width or per-vertex colors.

## Sources and historical limits

[W3C SVG 2 cubic Bezier description](https://www.w3.org/TR/SVG/paths.html#PathDataCubicBezierCommands)
is a terminology/reference source for cubic endpoints and control points. The
neighbor derivatives and the Swift geometry type are described and implemented
for Wupsy here; no external implementation, SVG parser or library is incorporated.
No specification prose or example implementation is copied. This is a mathematical
derivation with explicit requirements/tests, not a claim of a clean-room process:
the prior Wupsy code was inspected and compatibility is intentional.

Visual calibration used a desktop recording made by the user, including width, color and soft decay. The factor 0.15 and five subdivisions were already present before native integration; their pre-versioning origin remains incompletely documented. We do not claim those constants originally arose from user tests or that the mathematical description retrospectively clears the previous implementation. The current default is deliberately retained for compatibility. No video or private calibration material is included.

## Validation

Known-point, endpoint, straight-line, corner, reversal, duplicate and boundary tests
check the mathematical conditions. Default geometry fingerprints are captured from
the preceding accepted implementation, using only synthetic prototype paths.
They protect the accepted vertex positions/colors/counts, not an inferred foreign
algorithm. Local GPU frame comparisons supplement these checks; they are not a
portable guarantee across GPU/OS versions. Separate tests cover absent-field loads,
strict validation, save/reopen, undo/redo, preview/desktop agreement and unchanged
sample/color/alpha sequences at different k. Manual visual acceptance remains separate.
