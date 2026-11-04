# Native Rain random generation

## Implementation basis

Rain now uses SplitMix64, the fixed-increment 64-bit generator published by
Sebastiano Vigna in 2015, following the SplitMix work of Guy L. Steele Jr.,
Doug Lea and Christine H. Flood (2014). The output mixer is David Stafford's
Mix13 variant, identified in that paper. It needs one UInt64 state and no dependency.

Sources consulted for this implementation:

- [Vigna's published recurrence and permission](https://prng.di.unimi.it/splitmix.c)
  (`splitmix64.c` currently redirects to this file): exact fixed increment,
  mixing constants, shift distances, operation order and unsigned wrap semantics.
- [Fast Splittable Pseudorandom Number Generators](https://gee.cs.oswego.edu/dl/papers/oopsla14.pdf),
  Steele, Lea and Flood, OOPSLA 2014: algorithm background, not a source-code import.

The Swift source was written for Wupsy from that documented arithmetic.
The author publication, including its C expression of the recurrence, was inspected;
this is not a claim of a clean-room process or an independently invented algorithm.
No external implementation file or library was copied into Wupsy. Wupsy-specific
choices are the stream packing, typed purpose tags, Float conversion and Rain use.

Vigna's publication dedicates copyright and related rights to the public domain
where possible, also grants use/copy/modification/distribution with or without fee,
and disclaims warranties/liability. Its authorship and source remain acknowledged
in THIRD-PARTY-NOTICES.md (also included in the app). No Java or ACM paper source
code is incorporated. This does not retroactively clear the removed PCG's origin.

## Exact arithmetic contract

All values are unsigned 64-bit integers; addition and multiplication reduce modulo
2^64. Each draw first adds `0x9E3779B97F4A7C15` to the state, then mixes a copy:

1. XOR with its logical right shift by 30; multiply by `0xBF58476D1CE4E5B9`.
2. XOR with its logical right shift by 27; multiply by `0x94D049BB133111EB`.
3. XOR with its logical right shift by 31 to produce the word.

The stored state is the incremented value, not the mixed output. Zero is a valid
seed; there is no warmup. Swift `&+`/`&*` and UInt64 shifts specify this arithmetic.
Rain takes the upper 24 bits and divides by 2^24 as Float: the numerator is exactly
representable and the result is in [0,1), including 0 and excluding 1. Full-word
Float conversion is avoided because it can round to the excluded upper endpoint.

## Separate Rain purposes

Initial state is `(UInt64(sceneSeed) << 32) | purpose`, with distinct 32-bit tags:
`RAIN=0x5241494E`, `LENG=0x4C454E47`, `DROP=0x44524F50`.
Unlike XOR of two 32-bit values, packing makes the input pair unambiguous.
These are separate local generator instances, not a new public scene parameter.

- Layout consumes four fractions per instance: cross-axis position, initial travel
  phase, one of eight depths, and alpha between the existing opacity bounds.
- Length consumes one fraction per instance for the existing 0.5/1/1.5 classes.
- Profile choice consumes one fraction per instance when three profiles are present.

Independent means separate draw positions: extra shape draws do not move layout
or another purpose's cursor. It does not mean provably non-overlapping or
statistically independent full-period sequences; all use the same recurrence.
This is deterministic visual variation, not a cryptographic generator.

## Compatibility and visual effect

The former PCG-XSH-RR implementation had no recorded concrete source. It is removed, not reformatted
or retained as a compatibility branch. The concrete historical implementation source remains unverified; removal is not retrospective license clearance. See [third-party notices](../THIRD-PARTY-NOTICES.md).

The scene schema, UInt32 seed range, editor, renderer, padding, budgets, count,
32-byte instance layout, depth scales, speed/length/width rules, masks and playback
clock are unchanged. No project is rewritten or migrated. The same stored seed now
produces different positions, phases, depth assignments, opacity and class/profile
choices from old builds. Exact old frames are intentionally not preserved.
Reopening/rebuilding with the new implementation is stable for the same inputs.
There is no per-frame randomness; profile dimensions and depth still provide the
existing size/speed diversity. The user-requested two/three-variant aesthetic is
retained; visual acceptance of the new distribution remains a GUI decision.

## Verification basis

Known-word vectors for states 0, 1 and UInt64.max were calculated separately using
arbitrary-precision Python integers and explicit reduction modulo 2^64, not copied
from an old PCG golden prefix. Seeds producing first output 0/UInt64.max were
obtained by inverting each XOR/right-shift and odd multiplication modulo 2^64;
these exercise exact Float endpoints. Other tests check seed boundaries, purpose
packing, independent draw positions, population ranges, all depths/profiles,
density prefixes, profile edits, codec roundtrips and deterministic GPU frames.
Existing Rain editor, profile, pause/resume and playback tests remain applicable.
These checks do not claim a full statistical certification of the generator.
