# Third-party notices and provenance

## Ambient origin

Wupsy is derived from [Ambient](https://github.com/Claude-Reverser/Ambient). The original Copyright (c) 2026 Claude-Reverser and Ambient contributors and complete MIT terms are preserved in [LICENSE](LICENSE), which accompanies the application. A fresh publication history does not replace those rights or notices.

## Native Rain SplitMix64

Rain uses a Swift implementation of the fixed-increment SplitMix64 recurrence published by Sebastiano Vigna (2015), following Steele, Lea and Flood's SplitMix work (2014), with David Stafford's Mix13 mixer. Constants, shifts, wrapping arithmetic and operation order were checked against [Vigna's publication](https://prng.di.unimi.it/splitmix.c). The algorithm/constants are credited to those sources, not claimed as Wupsy inventions.

The publication dedicates copyright and related rights to the public domain where legally possible and additionally permits use, copying, modification and distribution for any purpose, with or without fee. It disclaims warranties, including merchantability and fitness, and author liability for consequential or other damages arising from use. No external implementation file, Java source or PRNG library is bundled. See [the implementation basis](docs/RAIN-RANDOM.md) for the actual consulted sources, stream packing and Float mapping.

## Native CursorTrail geometry

The current position-only cubic Bezier helper follows documented endpoint/neighbor-derivative requirements and exposes a configurable control-arm amount. W3C SVG is a terminology reference; no SVG implementation or parser is included. Visual calibration used the user's own desktop recording, which is not distributed.

The default 0.15 factor and five subdivisions predate native integration; their pre-versioning origin remains incompletely documented. The current derivation and compatibility tests do not retrospectively clear the previous implementation or imply a clean-room history. See [the curve contract](docs/CURSOR-TRAIL-CURVES.md).

## Historical components and unresolved limits

Earlier revisions contained an external-water-shader behavior port, inspected Clouds/Rain behavior, imported particle preset metadata and a PCG-XSH-RR implementation with incompletely documented concrete origin. SurfaceAdvection and WaterSurface were subsequently removed as well. These are historical records, not current supported effects, recognizers or codec compatibility.

The earlier water port's and inspected shader/preset material's underlying redistribution rights were not independently verified. Removal and a fresh repository do not grant rights or settle historical provenance. No original shader source/bytecode, workshop packages, downloaded wallpaper photos, engine textures, preset payloads or personal video/reference frames are included in the prepared snapshot. Current user image/mask ownership must still be respected. The old PCG implementation is absent; its concrete historical source remains unverified.

## Historical RePKG format reference

The removed Swift PKG/TEX reader used [RePKG](https://github.com/notscuffed/repkg) as a format reference; no RePKG executable or dependency is shipped. Its previously retained MIT notice is conservatively preserved below. This historical attribution does not advertise current PKG/TEX support or assert that a notice is unnecessary merely because the reader was removed.

MIT License

Copyright (c) 2019 notscuffed

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## System libarchive

Library Backup dynamically links macOS's system libarchive. No implementation source or library binary is bundled. Upstream is principally BSD-2-Clause, with individual file notices controlling: [libarchive COPYING](https://github.com/libarchive/libarchive/blob/master/COPYING) and [Apple's distribution](https://github.com/apple-oss-distributions/libarchive). Sources/CArchive/shim.h declares the used public ABI subset only.

## Build tools

The separately installed ds-store and mac-alias Python packages are build-time DMG layout tools, pinned in scripts/requirements-dmg.txt, and not embedded in the application. macOS system frameworks are dynamically linked; no browser or RePKG executable is bundled.

## Synthetic fixtures and branding

The Test-Wallpaper fixture READMEs identify original procedural pixels/maps and generators under the repository license. They are distinct from user projects and private historical reference media.

The separately treated WSS graphics are Brand/Wupsy-Logo-v2.png, Brand/Wupsy-MenuBar-Icon-v1.png and Brand/WSS_Logo.png, including only their specifically identified technical representations. See [the German policy](BRANDING.md), [English policy](BRANDING.en.md) and [Brand/LICENSE](Brand/LICENSE). Unchanged official application/DMG/source copies may retain these graphics; modified builds/forks must remove/replace them unless separately permitted, to the extent corresponding rights exist and subject to prior grants.

Their AI-assisted creation and selection do not establish exclusive copyright or registered trademark rights. The policy does not change Ambient's MIT license/copyright, retrospectively restrict Ambient graphics already released under MIT, or classify other assets as branding. Existing rights take precedence. The provenance of any underlying third-party material is not cleared by a new policy.
