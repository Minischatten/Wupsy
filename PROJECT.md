# Wupsy project guide

Wupsy is a native wallpaper and desktop-widget app for macOS 14+ on Apple silicon.
It uses SwiftUI/AppKit, Metal and macOS system frameworks.
The package uses Swift 5 language mode with a Swift 6 toolchain.
Supported content includes media, local web content and editable native WSS scenes.
External Wallpaper Engine projects, containers and arbitrary shaders are unsupported.
Effect contracts describe the current native implementation, without import profiles
or emulation of an external wallpaper runtime.

## Read only what the task needs

Nur die für den aktuellen Auftrag erforderlichen Dokumente lesen.
Zusätzliche Dokumentation ausschließlich bei konkretem Bedarf.
Nicht vorsorglich alle Effektverträge laden.

This guide is a documentation entry point; it is not automatically loaded by Codex.
For an effect task, use the index, then open only the relevant effect contract.
Follow its shared/specialist links when the task requires that detail.

## Repository map

- `Sources/Wupsy`: app UI, library, native document/renderer, editor and lifecycle.
- `Sources/CArchive`: ABI declarations for system libarchive.
- `Tests`: isolated unit, filesystem, renderer, editor and recovery checks.
- `Test-Wallpaper`: synthetic fixtures and their parameter/rights descriptions.
- `scripts`: formatting, build/packaging and deterministic fixture generation.

## User files and ownership

Import copies content into the managed library; external originals stay unchanged.
Editing uses independent immutable asset generations; do not overwrite originals.
Never use productive user libraries, preferences or personal wallpapers for checks.
Use injected roots/preferences and synthetic fixtures; preserve Undo-owned assets.
Invalid/unsupported projects fail explicitly rather than being regenerated or converted.
Do not infer cleanup ownership from plausible names or paths.

## Documentation routes

- Product, usage and content: [README](README.md), [scene support](SCENE-SUPPORT.md).
- One effect/layer: [effect index](WSS-EFFECTS.md).
- Image-effect coordinates/stacks: [shared contracts](docs/effects/COMMON.md).
- JSON, assets, validation and codec: [scene format](WSS-SCENE-FORMAT.md).
- Editor workflows: [editor](docs/EDITOR.md).
- Ownership, save/preview and lifecycle: [architecture](docs/ARCHITECTURE.md).
- Backup and restore: [backup format](BACKUP-FORMAT.md), [restore transaction](RESTORE-TRANSACTION.md).
- Development/check commands: [contributing](CONTRIBUTING.md).
- Packaging/signing: [distribution](DISTRIBUTION.md).
- Widget packages: [widgets](WIDGETS.md).
- Security reporting: [security](SECURITY.md).
- Attribution/history: [third-party notices](THIRD-PARTY-NOTICES.md).
- Branding rights: [Deutsch](BRANDING.md), [English](BRANDING.en.md).

Technical parameter/format contracts live at their linked owner, not in this guide.
Historical provenance and visual QA notes are distinct from current technical rules.
