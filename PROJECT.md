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

## Git

**All Git commit messages must be written in English.**

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
- Independent technical analysis (German, snapshot of `7943738`):
  [analysis report](docs/analysis/Wupsy-Analysebericht-0.8.0.md).

Technical parameter/format contracts live at their linked owner, not in this guide.
Historical provenance and visual QA notes are distinct from current technical rules.

## Release README requirements

Before every release, review README.md and README.de.md for accuracy,
completeness and consistency with each other. Update both to match the
features shipping in that release. Keep general product descriptions
version-independent where possible and omit separate lists of unreleased
features. Document unreleased work in this guide or the relevant technical
documentation.

## Release website requirements

Every release must include an update to the official
[WirdSchonSoftware website](https://wirdschonsoftware.com/). Update the
displayed Wupsy version in both German and English for each published
version. Update both feature descriptions when the release changes the
features covered by the website. After the FTP upload, have quality
control verify the public site in both languages before closing the release.

## Wupsy 0.8.0 release preparation

The local candidate is version 0.8.0 (build 4) for ARM64, based on
`cce284863797acf05d9f31092734239d688341fa`, the starting tip of local `main`
and `origin/main`. The current published release is
[v0.7.0](https://github.com/Minischatten/Wupsy/releases/tag/v0.7.0).
The release README review is complete for both languages. The public
release text is in the [bilingual draft](docs/releases/0.8.0-DRAFT.md).

Local verification on a physical Apple silicon Mac with macOS 27.2.1 and
Xcode 27.2 passed formatting, strict on-screen Metal presentation, and the
ARM64 Release build using the official packaging scripts and a separate
SwiftPM build directory. Bundle identity, version 0.8.0, build 4, minimum
macOS 14.0, English and German localization, and the ad-hoc app signature
were verified. The bundle inventory contains the expected localization,
Music Notes atlas, branding and notices, without personal wallpaper,
diagnostics or test fixtures. The license, branding and attribution copies
match the repository files.

The read-only DMG verification passed the disk image checksum, Finder
layout, Applications link, app metadata and signature checks. The embedded
app has the same file contents as the standalone app. Artifacts are in
`dist/release-0.8.0/`. The SHA-256 for `Wupsy-0.8.0.dmg` is
`ad51c89b8cbfb383aecf49f9d1c4afda1c8e0cc9bb6ea54a228d4295bb4b4dea`.

The complete local test run used
`WUPSY_REQUIRE_METAL_PRESENTATION=1 swift test --build-system swiftbuild --jobs 2`.
Of 1,560 test cases, 1,548 passed, one failed with six assertion failures,
and 11 were skipped. The failed
`WSSRemovedEffectTests` case still expected the old generic error path.
The decoder correctly rejected each unsupported effect and reported its
specific path. The assertion was updated to require that path, with no
product code change. The focused rerun covered removed effects, WSS failure
presentation, import and editor error localization, and strict Metal
presentation. It reported 24 passed, zero failed and one skipped. This
rerun covered the changed test and its related suites. The 11 skips in the
complete run were opt-in fixture, performance, or export tests. Test,
build and verification logs are alongside the artifacts.

The maintainer's Apple silicon macOS VM run for build 4 completed 1,560
tests with 1,547 passed, zero failed and 13 explained skips. The Release
build had zero warnings, and the built app started successfully. The run
used the standard VM Metal settings. Its report returned exit code 1
because the geometry warning scan matched `nan` inside `PanAnd` in an
XCTest status line. The [VM verification command](scripts/verify-release-vm.sh)
now excludes XCTest case and suite status lines and matches NaN and
Infinity as standalone terms. The updated report was checked against the
available physical-Mac logs and synthetic positive and negative examples.

The maintainer accepted the packaged DMG on a physical Mac. GitHub CI for
`65d9efd9f0c8d4ec924b8c2b88f315a356114690` passed formatting, packaging,
localization and app registration on macOS 26.7.2 (arm64, Swift 6.3.3).
Of 1,560 tests, 1,546 passed, one failed and 13 were skipped. The failed
`PerformanceDiagnosisTests` case had no desktop snapshot, desktop layer
count or editor snapshot at the assertion point. Both diagnoses had
already attached their measurement collectors. The test relied on the
first periodic samples surviving until a fixed delay expired. A late
sample and an intervening invalidation are both possible. The CI result
does not identify their order. The asserted values require no confirmed
Metal presentation.

The test now waits for the panel to grow within the existing time budget
and samples both diagnoses directly after the layout checks. All original
assertions and player identities remain in place. On the physical
Apple silicon Mac running macOS 27.2.1, the affected test passed ten
consecutive standalone runs. The subsequent `PerformanceDiagnosisTests`
group passed all five tests with zero failures and zero skips. Formatting
and Git diff checks passed. The existing DMG still matches the SHA-256
above, and the standalone app signature verifies. Version and build remain
0.8.0 and 4.

### Published release

[Wupsy 0.8.0 (Build 4)](https://github.com/Minischatten/Wupsy/releases/tag/v0.8.0)
was published on 2026-11-26 as the latest stable release. The annotated
tag `v0.8.0` points to `e8d613a57b02f7c56069c8782b7143a2106319ec`.
The uploaded `Wupsy-0.8.0.dmg` and `Wupsy-0.8.0.dmg.sha256` came
from the successful GitHub CI run accepted by the maintainer. The CI
image verified as ARM64, version 0.8.0, build 4, with a valid ad-hoc app
signature and the expected Finder layout.

The public release page and both assets were retrieved without
authentication. Both downloaded assets matched the upload files
byte-for-byte, and the downloaded DMG passed the published SHA-256
check. Its SHA-256 is
`864443c318ba9e0f716e4b83723d038ae84b9b89fad346c46f81e25a9589d3a8`.
The public `releases/latest` URL resolves to `v0.8.0`. The app's update
endpoint returned a published, stable `v0.8.0` with the expected release
URL. Under the existing version comparison, 0.7.0 sees an available
update and 0.8.0 is current.

Quality control subsequently accepted the actual in-app update from 0.7.0 to
0.8.0 (build 4) in a macOS VM. The update notice appeared with the app icon
and text centered as intended. The download link, installation and macOS
security approval worked. Wupsy 0.8.0 started with the existing library intact.
An initial manual functional check found no issues.

The Wupsy 0.8.0 product overview was published in German and English on the
official [WirdSchonSoftware website](https://wirdschonsoftware.com/).
After the FTP upload, quality control verified and accepted the public
site, including both project overviews, their links, both language
versions and the shared footer.

## Development builds for manual acceptance

A complete, directly launchable ARM64 Release app is sufficient for manual
acceptance during development. Report the full path to `Wupsy.app`. Create a
DMG only for release preparation or on explicit request. Ordinary development
tasks omit DMG creation, layout verification and checksum verification. Continue
running the relevant local tests, build checks and app-bundle checks.

## Native wallpaper errors

Import, playback preparation and editor opening share localized WSS failure
messages with copyable technical details. Only a higher declared WSS version
or an unknown field, effect or layer type can suggest a newer Wupsy version.
Invalid data, resource failures and storage errors retain separate guidance.
See the [WSS format contract](WSS-SCENE-FORMAT.md).

## Web wallpaper import (finding A2, A2.1)

Status: completed. Quality control accepted A2 and A2.1 manually on
2026-11-28: single HTML file import, complete web folder import, the size of the
native import panel, content-specific import messages and the distinction
between files and project folders. A1 is the next open correction. Phase 3.3
remains deferred.

Reproduction on `7943738` with synthetic data and an injected library: importing
one standalone HTML file copied all nine entries of its parent folder, including
a second page, its resources, an unrelated text file and a subfolder. An
unrelated symlink in a subfolder made the same single-file import fail as
unsafe. Cause: the importer treated every non-GIF web source as a project and
copied the entry's parent folder, whether a file or a folder had been selected.

Correction: only an explicitly selected folder copies a project tree. See
[web import boundaries](docs/ARCHITECTURE.md#web-import-boundaries). A
successful single-file HTML import shows a notice (also covering drag and drop),
and rejected folders get a message matching their content. Existing library
entries are unchanged. Version and build
remain 0.8.0 and 4.

Consequences:

- The existing requirement of a top-level `index.html` for web folders is kept
  deliberately (maintainer decision, 2026-11-28). Selectable start files are not
  part of this correction.
- A project whose start page has another name can be imported with its resources
  only after renaming that page to `index.html`. Before, selecting that file
  copied the surrounding folder.
- A `preview.jpg` next to a single HTML file is no longer copied, so such an
  entry has no thumbnail from it.

Local checks: `WebImportTests` and `WebImportRenderingTests` (file and folder
import, links, rollback, reload, notices, WebView rendering and blocked reads
outside the managed folder) together with the existing import, library,
localization, backup and restore suites.

Results on 2026-11-28 (physical Apple silicon Mac, macOS 27.2.1, Swift 6.4.2):
the selected suites, including WSS import grouping, ran 162 tests with zero
failures. Formatting and Git diff checks passed. The ARM64 Release app in
`dist/a2-html-import/Wupsy.app` passed the bundle, localization and ad-hoc
signature checks. Synthetic acceptance data and German instructions are in
`dist/a2-html-import/testdaten/` (untracked). The full test suite was not
repeated.

For the next release, update README.md and README.de.md: a single HTML file is
imported alone, and web projects with local resources need folder import. The
release notes should mention that earlier single-file imports may contain
parent-folder copies.

### A2.1: import panel and hints

Manual acceptance confirmed the A2 behavior but found the import panel far too
wide. Cause: the long HTML hint in `NSOpenPanel.message`. A probe on macOS 27.2.1
measured 880 points without or with a short message and 1,535 points with the
long German one. The panel now says only to select files or project folders.
Folder rejections distinguish a likely web project without top-level
`index.html` from a folder without any supported project.

AppKit stores the expanded panel size in the app preferences
(`NSNavPanelExpandedSizeForOpenMode`). A machine that opened the wide A2 build
keeps that width until the panel is resized or the key is removed. The wide
build was never released, so the app does not migrate the value.

On 2026-11-28 the selected suites ran 166 tests with zero failures; formatting
and diff checks passed. The failure sheet was rendered offscreen and inspected
in German and English. The ARM64 Release app in
`dist/a2.1-import-hints/Wupsy.app` passed bundle, localization and ad-hoc
signature checks. Acceptance data is in `dist/a2.1-import-hints/testdaten/`
(untracked; the regression tests create their own synthetic data). This build
passed the manual acceptance recorded above.

Proposal, not implemented: before copying a web folder, measure it and ask for
confirmation above about 2,000 files or 1 GiB. Consider rejecting trees that a
library backup cannot hold: more than 100,000 files (a whole-backup limit) or
more than 29 path levels below the project root. The two confirmation values are
estimates and need checking against real projects.

## Settings and quick actions

Open Settings from the menu bar extra or the Library’s three-dot menu.
Appearance contains interface sizing. Playback contains All Displays, Pause on
Battery and Power Saving. Library opens the existing backup and restore flows.
General contains Launch at Login and automatic update checks.

The menu bar extra shows playback status and offers Open Wupsy, manual pause
or resume, desktop widget editing, Settings, a manual update check, About and
Quit. Picture quality, scene resolution, frame rate and Stop remain in the
Library window.

## WSS performance diagnosis

Open Performance Diagnostics from the Library’s three-dot menu for desktop
playback, or use the gauge button inside the Editor’s live preview. Both views
are optional and sample independently while open. The desktop panel starts
closed, selects a display independently of its own position, and can join
eligible full-screen Spaces. Expanded details include Wupsy process CPU
usage and memory figures. System CPU utilization and both GPU utilization
scopes are omitted, including placeholder rows. GPU render duration retains
its existing meaning. Closing a view stops its collection.
See [measurement semantics and diagnosis views](docs/ARCHITECTURE.md#wss-performance-measurement).
See [stage 4 resource comparison](docs/ARCHITECTURE.md#stage-4-resource-comparison)
for the local A/B measurements and their limits.

## Native desktop pause

Manual pause keeps the native WSS desktop window, player and Metal view
in place and stops frame submissions. It resumes at the confirmed scene
position with Trail history intact. Stop and system resource relief retain
their teardown path. Editor and Library previews keep independent playback.
Section 1 passed manual acceptance on a physical Mac with both synthetic test
wallpapers and several existing wallpapers. The desktop image stayed visible
during pause and animation resumed without visible disruption. The panel showed
lower CPU activity and a drop of roughly 10 MB in physical footprint after a
few seconds. Memory reduction was outside the acceptance criteria. The
difference between manual and benchmark footprint readings remains unexplained.

The targeted run passed 162 tests, including strict Metal presentation, with
four optional tests skipped. Across five pause cycles, the CLI benchmark showed
zero frame submissions and GPU completions during pause, constant scene time
and resumed rendering on the same player. It received no presentation
confirmations even during playback. Pixel-identical image retention was
therefore outside the benchmark's evidence.

Section 2 keeps native WSS display slots by display identity. Display sleep,
system sleep and inactive sessions can overlap with manual pause. Returning
from these events or changing drawable geometry can request a bounded
frozen-time redraw. Ordinary visibility changes do not request new frames.

Pause freezes the current desktop wallpaper and Resume continues its
animation. Stop ends playback, discards pending wallpaper changes and
clears manual pause. Explicitly applying the same or another wallpaper
clears manual pause and starts the requested playback when other effective
pause reasons allow it. Automatic Apply, reapply, playlist rotation and
recovery preserve manual pause. Library preview and Editor playback remain
independent.

Section 2 was manually accepted. Single-display checks covered pause and
resume, Spaces, Mission Control, display scaling, lock and unlock, and about
ten seconds of system sleep. The visible frame and manual pause survived
wake, and Resume continued playback immediately. Explicit Apply started
playback directly after Stop and during manual pause. Basic playback and
global pause and resume worked on both displays over AirPlay. The accepted
automated run passed 151 tests, including strict Metal presentation.

AirPlay latency limited visual verification in Section 2. Later physical
two-display HDMI checks in Section 3 confirmed GIF pause and resume through
sleep, wake and temporary display loss, as well as a wallpaper change with
coverage retained on the second display. Other wired display-topology
scenarios remain unverified.

The subsequent Cursor Trail change lets existing samples fade on their own
display after the pointer leaves. Reentry starts a disconnected segment at
the existing emission cadence. During desktop pause, samples still use
frozen scene time. When playback resumes with the pointer outside the
display, the remaining trail fades normally. The Cursor Trail correction
was manually accepted in a multi-display setup and is complete. The
accepted automated run passed 85 tests, including strict Metal presentation,
with two optional export tests skipped.
See [desktop pause](docs/ARCHITECTURE.md#native-desktop-pause).

Section 3 is complete. It extends retained desktop pause to static images, videos and
animated GIFs. Video keeps its queue, looper and layer while the playback
rate is zero and the health timer is stopped. GIF retains the visible image
and its remaining frame time without a timer. Display reconciliation keeps
existing players and starts new paused video and GIF slots at the beginning.
Both formats retain the existing resource relief policy. HTML wallpaper
continues to unload on pause.

The HDMI wake trace showed that both original display slots were retired
before wake, while their display IDs later returned unchanged. The last
return was about seven seconds after system wake. A wake transition now parks
missing slots with their windows hidden and retains their paused players.
It completes after five quiet seconds and at most fifteen seconds after
the system, displays and session are available. Slots still missing at
completion are retired. New displays use the normal initial state after
the transition. Parked slots are released after 30 seconds of awake time
if the surfaces remain unavailable.

The physical two-display HDMI retest passed. Both original GIF players
survived the temporary display and the TV's second disappearance. Both
retained the same frame and remaining frame time, stayed manually paused
through stabilization, and continued on the same players on resume.
Resources were released at application quit. The library window was
visible after wake. Earlier traces showed its identity surviving temporary
geometry and display changes, and the cause of the earlier visibility
issue remains undetermined. The temporary diagnostics have been removed.

The cleaned ARM64 release passed a physical sleep and wake retest. A
wallpaper change on both physical displays also passed. The second display
kept wallpaper coverage throughout the transition.

Explicit playlist activation uses the same manual-pause handoff as an
explicit wallpaper Apply. Existing system pause reasons still apply.
Playlist rotation, startup restoration and automatic recovery preserve
manual pause. Manual acceptance confirmed that explicit playlist activation
started playback directly from manual pause. The final targeted run passed
133 tests, including strict Metal presentation. The ARM64 release, bundle,
signature, format and German and English localization checks passed.

Automatic fullscreen pause is deferred. The practical check on macOS 27.2.1
did not yield a sufficiently reliable fullscreen signal after the KVO fix.

Library arrow-key navigation passed manual acceptance. It follows the visible
wallpaper grid and changes the selection and preview without applying a wallpaper.

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

WSS v1 supports a sortable Fog layer. Adding Fog activates the scalar mask
tools with a black full-scene mask. Existing unmasked fog stays fully enabled
and shows a virtual white mask on selection. Its first stroke starts from white. The editor tint follows fog height
and softness. Legacy preset IDs are accepted on load and omitted on save.
The inspector exposes density, softness, structure scale, height, native SDR
color selection, directional arrows, numeric X/Y drift, a numeric speed field
and a speed slider. Slider input stays local during dragging and commits the
final drift as one Undo step. Reset to Defaults restores the shared fog settings and preserves the mask. See the [Fog contract](docs/effects/FOG.md) and
[preview architecture](docs/ARCHITECTURE.md#workspace-gestures-and-close).

## Native Slime development

Slime is planned as a sortable native WSS layer with its own Metal draw path.
The approved sequence is:

1. Prototype a hanging filament, pinch-off, retraction and bounded fall.
2. Integrate the hanging mode into WSS and the editor.
3. Add independent drops and source regions.
4. Add surface flow guided by an open Bézier path.
5. Add scalar masks for surface flow.
6. Evaluate optional local background distortion.
7. Explore an optional placed slime puddle or catch surface with temporary impact
   deformation, slowly decaying waves, optional small splashes and bounded
   transient spreading. Material accumulation must stay bounded. Evaluate
   whether existing Ripple techniques fit when this phase is designed.

Phase 1 is complete and visually accepted, including the Phase 1.1 material
refinement and the Phase 1.2 filament retraction. The accepted material uses
analytic normals derived from the filament and drop shapes for softer, localized
reflections. Quality control also visually accepted the post-release geometry,
including transient thickening, a rounded tip and smooth deceleration into the
anchor. This prototype is the basis for future phases.

The isolated debug preview uses the existing playback clock and a bounded
procedural draw. It includes a green-tinted material and a lighter translucent
material on synthetic dark and light backgrounds. All four focused Slime tests
for Phase 1.2 passed on a Mac Studio with Apple M4 Max, including fixed-time
Metal pixel checks of the retracting tip. The debug window had already received
Metal drawable presentation callbacks during Phase 1.1 on that Mac.

From the repository root, run `swift run --jobs 2 Wupsy --slime-preview`.
Space pauses or resumes, S toggles quarter speed, B changes the background and M
changes the material. The 1, 2 and 3 keys pause 0.1 seconds before, at and 0.1
seconds after pinch-off. The 4 and 5 keys pause 0.35 and 0.8 seconds after
pinch-off for retraction inspection. Left and Right step by 1/60 second, R restarts and
Escape closes the preview. The launcher bypasses regular app startup.

### Phase 2

Slime is a sortable WSS v1 layer with the shared Metal renderer, Canvas anchor
placement, native SDR color selection and a German and English inspector. The
existing save, undo and playback paths manage it. The editing Canvas shows the
resting anchor and Live Preview shows the animated cycle. See the
[Slime contract](docs/effects/SLIME.md).

The targeted run on a Mac Studio with Apple M4 Max passed 51 tests with zero
failures. One optional generated-project test was skipped because its fixture
environment was absent. The two-layer Slime fixture completed Metal rendering
and confirmed on-screen presentation. A final run of all ten Slime tests passed,
including the updated Metal pixel and presentation checks. Formatting and Git
diff checks passed.

The signed ARM64 development Release app is at
`dist/slime-phase-2/Wupsy.app`. Bundle metadata, ad-hoc signature, English and
German localization, and the 14 Slime labels in each built language were
verified. Quality control accepted the integrated editor and desktop workflow.

### Phase 2.1

Slime now has an independent native SDR reflection color below the material
color. Omission in WSS retains the Phase 2 highlight RGB (0.87, 0.97, 0.93), and
saving omits that default. Nondefault values round-trip and are rejected by
older strict Slime readers. See the [Slime contract](docs/effects/SLIME.md).

Five Metal frames of the synthetic two-layer scene matched Phase 2 byte for
byte on the Mac Studio with Apple M4 Max. All 20 focused Slime and WSS codec
tests passed, including on-screen Metal presentation, material color and alpha
checks, the AppKit inspector color well, independent layer settings, undo/redo,
and save/reopen. Formatting and Git diff checks passed. The verified ARM64
development Release app is at `dist/slime-phase-2.1/Wupsy.app`, with valid
ad-hoc signature and all 15 Slime labels in both languages. Quality control
accepted both Phase 2 and Phase 2.1.

### Phase 2.2

The follow-up work is tracked in these sections:

- **2.2 A** Diagnose and correct the editor Live Preview stall.
- **2.2 B** Decouple Slime anchor rotation from gravity and refine filament geometry.
- **2.2 C** Add an individual Slime cycle offset.
- **2.2 D** Add general WSS layer duplication in the editor.
- **2.2 E (accepted)** Extend the fall distance beyond 450.
- **2.2 E.1 (accepted)** Use scene pixels for Slime fall distance and inventory inspector units.
- **2.2 E.2 (accepted)** Unify Slime spatial parameters and measure the endpoint from the anchor.
- **2.2 F (complete, manually accepted)** Add general forward and backward frame stepping for paused Editor Live Preview.
- **2.2 F.1 (complete, manually accepted)** Keep the expanded preview playback button icon-only.

Phase 2.2 A is complete and manually accepted. The reproduction trace showed
that an animated Slime preview lost MetalKit draw callbacks after returning
from the expanded preview window. The existing editor transfer renewal now
includes animated Slime. It replaces the player and MTKView on a real window
transfer during continuous playback and preserves prepared resources and
the playhead. A manually paused transfer retains the paused player.

The acceptance trace covered about eight minutes, with 53 window-transfer
renewals, two resume renewals and four editor performance overlay on/off cycles.
Quality control could not reproduce a sustained stall during intensive editing,
window transfers, performance overlay toggles or pause and resume. The trace
recorded zero GPU failures and zero missing drawables. An independent causal
relationship with the performance overlay was not established.

The temporary trace and its launch argument were removed after acceptance.
The regular performance overlay and collector remain in place. Permanent
regression tests cover Slime, Starfield and Music Notes transfers, paused
Slime transfers, and Metal presentation through the regular collector.
All 32 targeted tests passed on Apple M4 Max, including confirmed Metal
presentation after both Slime window transfers. Formatting, Git diff, ARM64
bundle metadata and the ad-hoc signature were verified. The final development
Release app is at `dist/slime-phase-2.2A-final/Wupsy.app`.

Phase 2.2 B separates the rotated attachment from scene-relative gravity.
The analytic centerline blends the pad normal into the fall direction.
The neck and hanging drop use the tip tangent, and the released drop
continues from the release position. The synthetic alignment fixture covers
horizontal, sloped and vertical surfaces, nonuniform scaling and a separate
fall direction. The Slime-only direction semantics apply directly to internal
test scenes. All 25 targeted tests passed, including Metal pixel checks,
confirmed presentation on Apple M4 Max and the transfer regression tests.
Formatting, Git diff, ARM64 bundle metadata, German and English labels,
and the ad-hoc signature were verified. The development Release app is at
`dist/slime-phase-2.2B/Wupsy.app`. Quality control visually accepted the new
filament geometry and independent fall direction. Phase 2.2 B is complete.

At quality control's request, Phase 2.2 D precedes Phase 2.2 C. Duplicate
Layer is available in the editor layer-row context menu and through Command-D
outside text editing. A copy is inserted immediately below its source in the
visible list and selected. The list retains manifest order. The transaction
assigns new editor layer and image-effect IDs, and a fresh persistent ID to
a copied image depth target. A copied Music Notes layer retains its existing
target and path. The candidate must pass manifest and native resource
validation. Copies share immutable assets until edited. Undo and Redo
restore the model, editor identities, selection and referenced generations.
The final focused run passed 46 tests on Apple M4 Max, including confirmed
Metal presentation of duplicated Slime layers and the Slime window transfer
regression. Formatting, Git diff, ARM64 bundle metadata, the ad-hoc signature
and both duplicate menu labels were verified. The development Release app
is at `dist/slime-phase-2.2D/Wupsy.app`.

Phase 2.2 D.1 moves the duplicate directly below its source in the layer list.
It is drawn immediately after the source. Selection, Undo and Redo follow the
duplicate, and other layers retain their order. The focused run passed 20 tests
with two opt-in export tests skipped. The targeted Slime transfer test passed on
its first run. A separate two-layer CursorTrail Metal test passed, checking shared
pointer input, separate sample histories, additive output and frozen history.
CursorTrail duplication remains available under the existing scene budget.
Formatting, Git diff, ARM64 bundle metadata and the ad-hoc signature passed.
The development Release app is at `dist/slime-phase-2.2D.1/Wupsy.app`.
Quality control accepted Phases 2.2 D and D.1. Duplicates are independent and
appear below the source. CursorTrail remains duplicable for its confirmed
creative use. Extended practical wallpaper editing produced no further render
stall.

Phase 2.2 C adds a persisted Slime cycle offset and a percentage field in the
inspector. New Slime layers use the midpoint of the largest circular phase gap,
with deterministic tie-breaking. Duplication retains the source offset exactly.
Zero speed still shows the resting anchor. The four-layer synthetic scene
uses identical speeds and distinct offsets. All 38 targeted tests passed,
including the real inspector field, prepared-resource reuse, duplicate and
save semantics, Metal pixel checks and confirmed presentation on Apple M4 Max.
Formatting, Git diff, ARM64 bundle metadata, the ad-hoc signature and both
inspector labels were verified. The development Release app is at
`dist/slime-phase-2.2C/Wupsy.app`. See the [Slime contract](docs/effects/SLIME.md).
Quality control manually accepted Phase 2.2 C. The independent cycles meet
the visual requirements.

Phase 2.2 E expands Slime fall distance using the scene span along the fall
axis and the longitudinal transform scale. Long falls extend the minimum
cycle as needed and preserve the existing acceleration. Disjoint quads keep
the gap between the attachment and the drop out of fragment work. See the
[Slime contract](docs/effects/SLIME.md). All 32 focused tests passed, including
long-fall Metal pixel checks and confirmed presentation of the synthetic tall
scene on Apple M4 Max. Formatting, Git diff, ARM64 bundle metadata and the
ad-hoc signature were verified. The development Release app is at
`dist/slime-phase-2.2E/Wupsy.app`. Quality control accepted the extended fall
distance, including long falls.
The review found that local Slime units made it difficult to predict where
drops would reach in the image.

Phase 2.2 E.1 stores the fall distance in scene pixels and converts it to the
local cap at render time. The existing acceleration, fade and cycle
calculation still use local units. The Inspector's upper bound uses the
canvas projection along the fall direction. See the [Slime contract](docs/effects/SLIME.md)
and the [equal-distance fixture](Test-Wallpaper/WSS-Slime-Fall-Pixels-v1/scene.wss.json).
All 32 targeted tests passed, including Metal pixel comparisons at two
output resolutions and confirmed screen presentation on Apple M4 Max.
Formatting, Git diff, ARM64 bundle metadata, the ad-hoc signature and both
localized labels were verified. The development Release app is at
`dist/slime-phase-2.2E.1/Wupsy.app`.
Quality control manually accepted the scene-pixel distance in E.1.

Phase 2.2 E.2 measures the projected drop endpoint from the anchor center
and stores filament length, reference width and reference drop diameter in
scene pixels. The pad transform sets the attachment dimensions separately.
See the [Slime contract](docs/effects/SLIME.md) and the
[800-pixel fixture](Test-Wallpaper/WSS-Slime-Spatial-v1/scene.wss.json).
The 32 targeted tests passed, including Metal pixel checks and confirmed
presentation on Apple M4 Max. The localized inspector labels, ARM64 bundle
and ad-hoc signature were verified. The development Release app is at
`dist/slime-phase-2.2E.2/Wupsy.app`. Quality control manually accepted Phase
2.2 E.2, completing acceptance of Phase 2 through Phase 2.2 E.2.

Earlier internal Slime test wallpapers are intentionally incompatible with
the accepted spatial schema. The old filament-width and drop-size multipliers
are now scene-pixel dimensions. Filament length is measured on the segmented
centerline, and fall distance is measured from the anchor. No migration or
legacy mode is provided for unpublished Slime scenes. Published WSS effects
retain their existing format and semantics.

Phase 2.2 F implements paused frame stepping in both editor preview sizes.
Each click moves the scene clock by one interval of the editor target frame
rate (currently 1/30 second). Rapid clicks
all count while rendering can skip intermediate targets. The first effective
step clears the editor’s transient CursorTrail history. Playback resumes at
the selected time and subsequent pointer input builds new trails. Paused window
transfers keep the player and prepared resources and renew only the MetalKit
view to recover drawable presentation in the destination window. See the
[editor documentation](docs/EDITOR.md).

All 84 focused regression tests passed on Apple M4 Max, including confirmed
Metal presentation in the normal and expanded preview, a pending backward
step across a window transfer, pixel comparisons for all nine analytic
effects, and desktop pause and Library preview coverage. Quality control
manually accepted forward and backward stepping, Slime and Music Notes
timing, transfers between preview windows, and resuming playback.

Phase 2.2 F.1 keeps the playback button icon-only in both preview sizes.
Both focused regression tests passed on Apple M4 Max, covering playback
toggles, window transfers, localization and frame stepping. Quality control
confirmed the corrected playback control in the final manual review.
Phases 2.2 F and F.1 are complete. The development Release app used for
acceptance is at `dist/slime-phase-2.2F.1/Wupsy.app`.

### Phase 3

- **3.1 (complete, manually accepted)** Add a direct drop at a point source.
- **3.1.1 (complete, manually accepted)** Clarify inspector units, remove duplicate editor button labels and analyze mixed import results.
- **3.1.2 (complete, manually accepted)** Group selected WSS components and report partial imports by item.
- **3.2 (complete, manually accepted)** Allow overlapping falls and an independent drop interval.
- **3.2.1 (complete, manually accepted)** Show the interval field and minimum only with fixed timing.
- **3.3 (next open phase)** Add a rectangular start region and deterministic interval and size variation.
- Complete joint acceptance and performance measurements after Phase 3.3.

Phase 3.1 adds the Direct Drop mode to the existing Slime layer. The default
Hanging Thread keeps its accepted cycle. Both modes share the anchor, material,
fall direction and anchor-relative endpoint. Direct Drop grows a short bulge at
the pad, then evaluates one falling drop from scene time. The inspector hides
the filament dimensions in this mode and preserves them for a later switch.

The synthetic [Direct Drop fixture](Test-Wallpaper/WSS-Slime-Direct-Drop-v1/scene.wss.json)
covers light and dark backgrounds, several fall directions and a Hanging
Thread reference. On Apple M4 Max, 32 fixed-time Metal images matched the
previous Hanging Thread renderer byte for byte. The final run passed all 40
focused regressions, including confirmed Direct Drop presentation after frame
steps in both editor preview sizes, window transfer and exact resume timing.
The verified ARM64 development Release app is at
`dist/slime-phase-3.1/Wupsy.app`.

Quality control manually accepted the Direct Drop behavior in Phase 3.1.
Phase 3.1.1 labels the anchor center and effective pad sizes in scene pixels.
Opacity remains on the existing 0–1 scale. Gloss and cycle speed are factors.
At enlarged interface scales the editor's custom Save, Save As and Revert
buttons carry the visible title while the toolbar retains it as its palette
label. The development Release app is at `dist/slime-phase-3.1.1/Wupsy.app`.

The Direct Drop fixture contains `scene.wss.json` and `assets/panels.png`.
Before the Phase 3.1.2 correction, the Library processed input URLs
independently. The full folder or manifest imported one scene, while selecting
the manifest and PNG imported a scene and a separate image. Selecting the
manifest and the **assets directory** reproduced the reported mixed outcome.
The scene was committed, while source resolution rejected the assets directory
and reported the source-detection error as `storage / unsupported`.
A genuinely missing PNG rejects the scene without a Library entry.
Successful scenes retained byte-identical assets after a Library restart.
The mixed import's scene reopened in the editor and was accepted for desktop
playback. The test cases left no orphaned import directories. Ten focused
tests passed. The original drop's exact URLs could not be established.

Quality control manually accepted the Inspector units and the editor toolbar
labels in Phase 3.1.1. Phase 3.1.2 groups explicitly selected WSS projects
with selected paths they reference and with selected directories containing
those paths. The Library publishes each project through the existing managed
import transaction. If publication fails, the report identifies the project
and the components left unimported. Partial results name imported wallpapers
alongside the failed sources. Unsupported source detection has its own
diagnostic category. WSS manifest and asset errors retain their specific
messages. All 53 focused tests passed, including the extended import matrix,
file URL drop providers, reopening and applying the managed WSS scene,
localized diagnostics and injected rollback. The development Release app
is at `dist/slime-phase-3.1.2/Wupsy.app`.

Quality control manually accepted the Direct Drop mode, the Inspector units,
the editor button labels, and dragging related WSS project components into
Wupsy together without a misleading failure report. Phases 3.1 through 3.1.2
are complete.

Phase 3.2 adds optional fixed drop intervals to Hanging Thread and Direct Drop.
The interval uses scene seconds. Cycle speed scales formation and retraction,
while detached drops keep the same acceleration regardless of interval or
cycle speed in fixed timing. Scene validation reserves at most eight concurrent
falls per source and 64 per scene. The analytic renderer checks only nearby
events and draws earlier drops using separate local quads. The automatic timing
of existing scenes remains the default.

The synthetic [overlap fixture](Test-Wallpaper/WSS-Slime-Overlapping-Drops-v1/scene.wss.json)
contains both modes, multiple intervals, long falls and an automatic reference.
On Apple M4 Max, 44 fixed-time Metal images matched the previous automatic
renderer byte for byte. All 18 focused final tests passed, including separate
rendered drop areas, deterministic stepping, confirmed presentation in both
preview sizes, transfer and resume. The development Release app for manual
acceptance is at `dist/slime-phase-3.2/Wupsy.app`.

Phase 3.2.1 shows the interval field and minimum interval only with fixed
timing in both Slime modes. Switching to Automatic Cycle retains the
stored interval. Four focused Inspector, localization and animation tests
passed. The development Release app used for manual acceptance is at
`dist/slime-phase-3.2.1/Wupsy.app`.

Quality control manually accepted the fixed interval and the livelier
appearance from overlapping falls, the context-sensitive Inspector and
the unchanged Automatic Cycle. Phases 3.2 and 3.2.1 are complete.
Phase 3.3 is the next open development task.

### Phase 3.3 planning

Investigate deterministic interval variation for point sources in both
Slime modes as well as the planned rectangular start region. Expose
variation as a percentage, with 0% retaining the current timing exactly.
Use variable gaps with Fixed Drop Interval and investigate optional
variation of the idle wait in Automatic Cycle. Keep formation duration
and fall acceleration unchanged. Evaluate from scene time and enforce
the existing minimum intervals and drop budgets at maximum variation.
Drop size variation and the rectangular start region remain in scope.

### Inspector units

Use scene-image pixels for distances and sizes, seconds for time, degrees for
angles, pixels per second for linear speed, and particles per second for
emission rates. Use percentages for normalized intensity and opacity where
meaningful, and percentages or clearly labeled factors for scaling. Keep
dimensionless factors, seeds and mathematical parameters in units that
describe their actual meaning. Local, scene and viewport coordinates must be
labeled according to the actual calculation. The
[Inspector units inventory](docs/INSPECTOR-UNITS.md) records where labels,
display conversions or changes to the effect model would be needed.

## Findings from the independent analysis

Identifiers refer to the [analysis report](docs/analysis/Wupsy-Analysebericht-0.8.0.md).
Only A1 and A2 are confirmed code defects.

Open correction:

- A1: stopping the transition-window observation also removes the desktop
  window's occlusion observer. User impact is unconfirmed.

Completed:

- A2: single HTML import copied the parent folder. Corrected and accepted, see
  [web wallpaper import](#web-wallpaper-import-finding-a2-a21).

Open investigations: B3 (macOS 14/15 unverified), B7 (GIF size limits), C1
(concurrent video cache export), C2 (GPU counter on a stalled command buffer),
C3 (decode cost of very large images).

Known limitations: B1 (web wallpaper scripts and network access, documented in
SECURITY.md), C4 (the Starfield color picker issue below).

Optional improvements: B2 (guard the private WebView key), B5 (widget timer
rate), B6 (window update observers), the test and style notes in section D.

Undecided: B4. Any change to the GitHub CI triggers or scope remains an open
decision.

## Known limitations

- **Intermittent Starfield color picker delivery.** The macOS color panel can
  show a new selection while the editor preview retains the previous color.
  In the Nov 20 GUI trace (`wupsy-color-panel-trace(1).log`, 15:13:57–15:14:06),
  the panel continued to emit color-change notifications without invoking
  either Starfield color binding setter. The preview continued rendering
  other scene revisions. Window and focus changes and shooting-star toggles
  are possible triggers. None has been confirmed, and the exact cause is unknown.
