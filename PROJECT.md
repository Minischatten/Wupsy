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

## Interface size

The Settings window offers 100%, 125% and 150% under Appearance. Open it
from the Library’s three-dot menu or the Wupsy menu in the menu bar.
Library, editor and separately hosted Wupsy panels share one live,
UserDefaults-backed setting. See [interface sizing](docs/EDITOR.md#interface-size).
Canvas coordinates, zoom and wallpaper rendering use their existing units.

## Native music notes, stage 1

WSS v1 supports sortable Music Notes layers with seeded activity in an editable
rectangle, three selectable note symbols, color, opacity, speed and direction.
Optional hover oscillates perpendicular to travel and uses a vertical axis at
rest. The inspector also offers rotation and Reset to Defaults. See the
[Music Notes contract](docs/effects/MUSIC-NOTES.md).

### Music Notes paths

- **Stage 2.1** supports the optional open or closed path model, strict WSS
  persistence and bounded CPU Bézier preparation. See the
  [path contract](docs/effects/MUSIC-NOTES.md#stage-21-path-data-and-geometry).
- **Stage 2.2** plays enabled paths in the Music Notes Metal renderer.
  Open paths fade at the restart, closed paths loop continuously, and both
  support forward and reverse travel. See the
  [playback contract](docs/effects/MUSIC-NOTES.md#stage-22-metal-path-playback).
- **Stage 2.3** adds inspector path controls and Canvas Bézier editing with
  coalesced Undo and throttled Live Preview updates. See the
  [authoring contract](docs/effects/MUSIC-NOTES.md#stage-23-path-authoring).

## Native fog

WSS v1 supports a sortable fog layer with Ground Fog and Atmospheric Fog presets.
The inspector exposes density, softness, structure scale, height, native SDR
color selection, directional arrows, numeric X/Y drift, a numeric speed field
and a speed slider. Slider input stays local during dragging and commits the
final drift as one Undo step. Reset to Defaults restores the insertion preset. See the [Fog contract](docs/effects/FOG.md) and
[preview architecture](docs/ARCHITECTURE.md#workspace-gestures-and-close).

## Known limitations

- **Intermittent Starfield color picker delivery.** The macOS color panel can
  show a new selection while the editor preview retains the previous color.
  In the Nov 20 GUI trace (`wupsy-color-panel-trace(1).log`, 15:13:57–15:14:06),
  the panel continued to emit color-change notifications without invoking
  either Starfield color binding setter. The preview continued rendering
  other scene revisions. Window and focus changes and shooting-star toggles
  are possible triggers. None has been confirmed, and the exact cause is unknown.
