# Contributing

Wupsy is a native macOS app derived from Ambient. Keep upstream copyright and license notices, identify sources for new code/assets and never include personal wallpaper packages, keys or local library data.

## Development and checks

Use Xcode with a Swift 6 toolchain, selected by xcode-select. The package uses Swift 5 language mode and system frameworks. Python 3.10+ is needed only for packaging layout tools and the standalone procedural fixture generators.

```sh
bash scripts/format.sh --check
swift test --build-system swiftbuild --jobs 2
bash scripts/build-app.sh
```

For focused changes, first run the relevant test filters. The complete suite includes renderer and native AppKit tests that may need a real macOS display session; optional environment-dependent skips must be reported rather than hidden. Use synthetic fixtures and injected roots/preferences, never productive user data. See [distribution](DISTRIBUTION.md) for bundle/signature checks and optional packaging.

Formatting is xcrun swift-format using .swift-format. The format script without --check edits source, tests and Swift scripts; run it deliberately. CI checks formatting/tests and builds a development DMG without signing secrets or automatic publication.

## Code and documentation map

Start with [PROJECT.md](PROJECT.md) and read only the contracts needed for the current task.

- Sources/Wupsy: SwiftUI/AppKit UI, managed library, native document/renderer, editor, widgets and lifecycle.
- Sources/CArchive: public ABI declarations for the dynamically linked system libarchive, not a vendored implementation.
- Tests: isolated unit, filesystem, renderer, editor, playback and recovery checks.
- Test-Wallpaper: self-generated fixtures and their parameter/rights descriptions.
- scripts: build/verification, formatting and deterministic fixture generation.
- [Editor](docs/EDITOR.md), [architecture](docs/ARCHITECTURE.md), [scene format](WSS-SCENE-FORMAT.md), [effect contracts via the index](WSS-EFFECTS.md), [Trail](WSS-TRAIL.md), [backup](BACKUP-FORMAT.md) and [restore](RESTORE-TRANSACTION.md) define the current contracts.

## Change requirements

Preserve saved precision, strict validation, resource limits and immutable asset ownership. A display-format change must not round stored data. A renderer change needs deterministic CPU/GPU checks where applicable and separate visual review. Test behavior and safety properties; do not replace reference values merely to make tests pass.

Save, Save As, active-wallpaper refresh, playlist switching and restore have distinct commit points. Keep stale-result rejection, cancellation and failure behavior explicit; consult architecture and restore contracts before changing them. Unsupported project data must fail with an actionable error rather than disappear or invoke a fallback converter.

Use independent immutable generations for image/mask/field edits. Do not overwrite original media, remove old generations needed by Undo or perform automatic cleanup of unproven ownership. Filesystem tests must cover failure and symlink/path boundaries.

New code/media must have documented origins and compatible permissions; algorithm names alone are not evidence of implementation provenance. Report security issues using [SECURITY.md](SECURITY.md).
