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

## Settings and quick actions

Open Settings from the menu bar extra or the Library’s three-dot menu.
Appearance contains interface sizing. Playback contains All Displays, Pause on
Battery and Power Saving. Library opens the existing backup and restore flows.
General contains Launch at Login and automatic update checks.

The menu bar extra shows playback status and offers Open Wupsy, manual pause
or resume, desktop widget editing, Settings, a manual update check, About and
Quit. Picture quality, scene resolution, frame rate and Stop remain in the
Library window.

## Interface size

The Settings window offers 100%, 125% and 150% under Appearance. Open it
from the Library’s three-dot menu or the Wupsy menu in the menu bar.
Library, editor and separately hosted Wupsy panels share one live,
UserDefaults-backed setting. See [interface sizing](docs/EDITOR.md#interface-size).
Canvas coordinates, zoom and wallpaper rendering use their existing units.

## Native music notes, stage 1

WSS v1 supports sortable Music Notes layers with seeded activity in an editable
rectangle, three note symbols and an optional treble clef, color, opacity, speed
and direction.
Symbol sizes are 4…512 logical canvas units, subject to the existing draw-time
region cap.
Optional hover oscillates perpendicular to travel and uses a vertical axis at
rest. The inspector offers independent strength and frequency for hover and
rocking, plus Reset to Defaults. See the
[Music Notes contract](docs/effects/MUSIC-NOTES.md).

Music Notes layers also support one freely placed symbol or one symbol fixed
at a percentage of the Bézier path. Single symbols can also rotate continuously
in either direction, in the image plane or about the local vertical axis.
Both reuse the note renderer. See
[single-symbol placement](docs/effects/MUSIC-NOTES.md#single-symbol-placement).

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

New paths start as a horizontal line. The inspector also offers an explicit
ellipse template. Switching Open/Closed toggles the closing segment and
preserves the authored anchor and grip coordinates. While editing a path,
Smooth Anchor aligns the selected anchor’s grips on demand.

Animated Music Notes can opt into per-note depth changes relative to a
selected source-over image layer. The five staff lines keep their layer
position by default and can opt into the same depth sections. See [depth changes](docs/effects/MUSIC-NOTES.md#depth-changes).

### Music Notes staff

Stage 3.1 adds optional WSS staff settings and bounded CPU geometry for five
static lines sharing the layer's movement frame and active curve. See the
[staff contract](docs/effects/MUSIC-NOTES.md#stage-31-staff-data-and-geometry).
Stage 3.2 composites the antialiased staff behind its notes in the same layer.
Stage 3.3 adds the staff Inspector and a passive preview for the selected layer
in the editing Canvas, using the same path and movement frame.

Open animated paths can optionally use an authored perspective taper for
both symbols and staff lines. See
[perspective along the path](docs/effects/MUSIC-NOTES.md#perspective-along-the-path).

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
