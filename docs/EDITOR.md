[English](EDITOR.md) | [Deutsch](EDITOR.de.md)

# Native editor

## Create or open

Create a native wallpaper in Wupsy or import a project folder containing scene.wss.json. Open the native wallpaper in the editor. Images and masks are user content; Wupsy does not supply personal reference wallpapers or convert external engine projects. An invalid project is an error, not a request to reconstruct missing files.

Importing the WSS project folder or its `scene.wss.json` entry uses the
relative paths in that manifest. If the same selection includes referenced
files or directories containing them, Wupsy imports that project once.
An independently selected image outside those references can still be
imported as an image wallpaper. The same rules apply to file selection and
drag-and-drop. If only part of a batch succeeds, the result lists the
imported wallpapers and the failed sources. A component associated with a
failed project is reported as unimported.


The layer list controls painter order. Add image, Rain or CursorTrail layers, reorder them, toggle visibility or delete layers while retaining a valid scene. Image transforms use logical canvas coordinates; image Add/Replace normalizes PNG/JPEG/HEIC/TIFF input to independently owned PNG data. Replacing an image preserves the layer's existing transform/effect semantics rather than automatically resampling its fields.

Select a layer and press Return, or double-click its name, to edit it in place.
The current name is selected. Return or moving focus away accepts a valid name,
and Escape cancels. Names can repeat and must fit on one line with 1 to 256
characters after trimming leading and trailing spaces. Invalid input leaves the
previous name in place. Each changed name is one Undo step. The inspector and
layer pickers show the new name, and Save stores it with the scene.

An image layer’s **Opacity** slider goes from 0% to 100% in 1% steps. The
inspector displays the current percentage, and the Live Preview updates as you
drag. A continuous drag is one Undo step. The setting affects both Live Preview
sizes and the saved desktop wallpaper.

## Image effects

Add Ripple, Clouds or Flow to the selected image, then select an effect to edit its
controls. See [shared stack ordering and validation](effects/COMMON.md), including
the distinction between slider convenience ranges and valid stored values.

- [Ripple](effects/RIPPLE.md): displacement, movement and spatial structure controls.
- [Clouds](effects/CLOUDS.md): noise, coverage, tone and supported inspector controls;
  see that contract for the initial mask and retained optional fields.
- [Flow](effects/FLOW.md): transport controls, direction painting and region semantics;
  see that contract for neutral insertion state, painting/erasing and atomic Undo.

Select an effect to inspect/edit its mask where supported. Scalar mask painting writes
independent generations, never the original file. The selected overlay is editor state;
it is not a persisted visual layer.

## Music Notes

The [Music Notes user guide](anleitungen/MUSIC-NOTES.md) shows how to animate
notes, draw your own paths, and set up depth changes and perspective.

If a native wallpaper cannot be opened, the library shows the WSS failure
reason. Use Details to inspect or copy the diagnosis. Higher WSS versions
and unknown features can indicate that a newer Wupsy version may help.

## Live Preview and performance diagnostics

Use the gauge in Live Preview to open optional performance diagnostics. The
preview measures frame timings independently of desktop diagnostics. Expanded
details show Wupsy CPU and memory figures. Closing diagnostics stops sampling.

## Duplicate a layer

Use **Duplicate Layer** in a layer row's context menu, or press **Command-D**
with a layer selected and focus outside a text field. The copy appears
immediately below the source row in the list and becomes selected. The list
continues to show manifest order, with later rows composited above earlier
rows. The copy retains the source placement and settings. Changes to a shared
image, mask or field use the usual independent asset generations. Undo and
Redo restore the layer and selection together.

## Slime

Choose **Slime** in the layer add menu. Select the layer and drag its resting
anchor in the Canvas. The transform handles resize and rotate the
attachment to match the surface. The fall direction stays relative to the scene.
Anchor X and Y in the inspector allow precise placement. X increases rightward,
Y upward. Use Live Preview to watch the full cycle while adjusting material
color, opacity, gloss, size, filament width and length, cycle speed, drop size,
fall direction and fall distance. Fall distance is measured from the anchor
center to the drop endpoint along the fall axis. Filament length, base width
and release diameter also use scene-image pixels and remain independent of
the attachment size. Slime layers can be named, hidden, reordered, undone,
and saved through the usual layer tools. See the [Slime contract](effects/SLIME.md).

## Fog

Choose Fog from the layer add menu. Fog starts with a black mask, an active
brush and a frame around the full scene. Paint to reveal it or hold Option
while painting to erase coverage. Selecting unmasked fog shows a full-coverage mask overlay without creating a mask.
The first stroke starts from full coverage. Removing a mask restores this view. The blue overlay follows the current height
and soft fade while the mask and frame stay fixed to the scene. The mask
menu supports importing, filling, clearing and removing the mask. Reset to
Defaults restores the fog settings and preserves the mask.
Reorder the fog layer to control foreground occlusion. Set density, softness, structure scale and height
in the inspector. Use the native macOS color picker to choose the fog color.
Set drift with the eight direction buttons, the speed slider or the numeric X/Y
fields. The speed readout follows the slider as you drag. Live Preview may skip
intermediate positions. Releasing the slider applies the final drift as one Undo
step. See the [Fog contract](effects/FOG.md).

## Rain and CursorTrail

[Rain](effects/RAIN.md) is a separate rectangular scene layer. Adjust its region
and rain controls, and place it between images for foreground occlusion. The Rain
contract defines profile actions, insertion defaults and density/count semantics.

[CursorTrail](../WSS-TRAIL.md) is a procedural layer controlled by the local pointer
in live preview/playback. Its contract defines controls, defaults, explicit palette
conversion and proportional lifetime/fade edits.

## Numeric fields and Undo

Numeric fields keep their displayed spelling when focused. Empty/incomplete text is permitted while typing. Return and successful focus loss commit valid, finite, in-range input. Invalid text keeps an error hint and does not change the document; Escape restores the latest model value. German decimal commas are accepted; direct input retains supported Float/Double precision.

Display rounding does not round persisted parameters. Focus without a text change preserves the original internal value even if the label is rounded. Slider/model updates refresh untouched fields; a modified draft remains editable while its cancellation baseline follows the newer model. Only real model changes enter document Undo/Redo. Save validates pending editing before publication.

## Canvas and preview

While paused, **Previous frame** and **Next frame** move scene time by one interval of the preview’s target frame rate. At 30 target FPS, each step is 1/30 second. The buttons flank playback in both the normal and expanded Live Preview. At the start of the scene, only the forward step is available. Every rapid click counts even if the preview skips some intermediate images. The first step that changes the time clears all CursorTrail traces. Trails build again from new pointer input after playback resumes at the selected time.

The static Edit Canvas shows image layout without effects, Rain or Trail. Live Preview renders the working native scene, using the same runtime as desktop playback. Pointer movement and preview time are not document edits. Parameter/structure changes can replace preview resources and clear transient trail history; pause/sleep/session gates do not rewrite the project.

## Save, Save As and close

Editing updates the working model. Save validates encoded JSON, referenced assets and loaded fingerprints, installs immutable assets first and atomically replaces scene.wss.json last. Save never chooses another desktop wallpaper; an already active matching UUID refreshes to the committed snapshot without changing playlist state.

Save As creates an independently owned managed project, limited to 512 MiB, with a new title/identity. Successful publication switches the same editor to clean B with empty Undo/Redo, leaving A and desktop/playlist references unchanged. Failed library publication may leave a complete unreferenced project; no automatic garbage collection is performed.

Closing resolves unsaved changes. Native backup captures saved state, not dirty editor drafts or Undo history. Restore resolves all editors and drains runtime before irreversible publication, then requires quitting/reopening. See [architecture](ARCHITECTURE.md), [backup](../BACKUP-FORMAT.md) and [restore](../RESTORE-TRANSACTION.md).

Managed static images can be opened with “Edit Wallpaper…” as independent WSS drafts. First Save offers an additional scene (default) or replacement of the original entry. Reopening the same source focuses its existing editor session. Only single-image inputs are accepted; multipage TIFFs are rejected. Normalization uses eight-bit sRGB PNG, so HDR/wide-gamut fidelity is not preserved. Source provenance remains session-only and is not encoded in scene JSON.

Image replacement keeps the source UUID and its current library position, so favorites and playlist references remain valid. It validates the opening receipt (record and source-byte fingerprint), publishes an independent project, then atomically replaces library.json. Source rename/removal/replacement/content changes are conflicts; the draft can still be saved additionally. Duplicate display names remain allowed. Neither external nor old managed image bytes are deleted. Replacing is supported during wallpaper and playlist playback. Inactive replacements do not switch the desktop; the playlist uses the scene on its next regular turn. Active replacements stage new renderer windows before exchanging only matching UUID slots, preserving pause, playlist timer and shuffle state. A newer action takes priority. A failed desktop update leaves the saved scene committed and reports a warning; the prior renderer is retained when synchronous startup fails. A pending Apply is retargeted without creating a second request. Display changes can defer automatic handoff; the next activation uses the saved scene. Startup is not a guarantee of a first visible GPU frame. Ordinary creation and Save As keep their existing naming flow.

## Completed acceptance

The maintainer reported final acceptance of managed-image editing and replacement on 2026-11-14:

| System | Tests | Failures | Skips | Practical GUI checks | Active playlist wallpaper replacement |
| --- | ---: | ---: | ---: | --- | --- |
| macOS 26 | 1,250 | 0 | 11 | Passed | Passed |
| macOS 27 | 1,250 | 0 | 11 | Passed | Passed |

These results cover the completed three-stage feature, including saving an additional scene, replacement with retained identity and order, and playback handoff during playlist rotation.

## Storm

Add a native Storm layer for visible lightning. Its inspector supports rename
(Return or Rename), exact numeric position, direction, RGB, geometry and event
controls and the native macOS color picker. Accepted edits use document Undo/Redo.
Selecting Storm shows a fixed authoring frame in the static Edit Canvas; move it,
use corners to scale (Shift: independent axes), or the round handle to rotate.
The frame maps to the existing position/direction/length/spread parameters.
Storm animation appears in Live Preview and desktop playback.
See [Storm](effects/STORM.md) for bounds, timing and compatibility.

Storm also offers independent Visible lightning and Storm illumination switches.
Use the existing impulse duration/flashes/interval for both. The separate Light
color picker, exposure intensity and shadow lift affect the complete wallpaper,
including foreground layers. Old projects open with illumination disabled.

Starfield adds a seeded rectangular sky, a free RGB picker, controlled color
variation, optional twinkling and X/Y drift. Select the layer to move/resize its
frame (Shift: independent axes); rotation is unavailable. Actual stars appear in
Live Preview, while the editing canvas remains image-only. See the
[Starfield contract](effects/STARFIELD.md).

The Starfield inspector also offers optional Shooting stars, disabled by default.
Frequency is shown as shooting stars per 10 minutes (0…120, fractions allowed);
stored rates remain per minute for compatibility. For example, 1 means one event
per ten minutes and 10 means one per minute. Speed and tail length use scene units.
Eight arrow buttons select compass directions; the numeric degree field and center
arrow show precise intermediate angles. Direction is 0° right, 90° up and 270° down,
with symmetric direction variation.
Meteors use the base color and are independent of the slow star drift.

Starfield also has an optional Milky Way section, off by default, with its own
native color picker and seed. Position X/Y are fractions of the region, band width
is a fraction of its shorter side, and angle is counterclockwise (0° horizontal,
90° vertical). Intensity, structure and dust lanes affect only the Milky Way.
Existing star and meteor distributions stay unchanged. The band follows star drift
periodically; with no other animation it remains static. Use Live Preview for the
rendered field; the existing Canvas rectangle controls the complete Starfield.

## Interface size

Choose Wupsy → Settings → Appearance to select 100%, 125% or 150%.
The setting is stored as the integer `interfaceScale` in the app's preferences.
Missing or invalid values use 100%. Change it while the Library, editor or a
Wupsy panel is open. The windows observe the same setting without reopening
documents. Preference changes do not enter the scene manifest or Undo history.

SwiftUI reads the shared metrics from its environment, including at the
roots of separately hosted AppKit windows. Shared typography, controls and
padding grow in logical points. Native input fields, their validation hints
and the application-owned Canvas controls consume the same metrics. The
Library's adaptive columns reflow, and the editor keeps its inspector and
layer list scrollable. Window limits and saved positions and sizes are still
in AppKit points. Native menus, file pickers and OS tooltips use system sizing.

The Library's image preview dimensions and the wallpaper resolution setting
are independent of interface size. Split-view changes may change the display
space available for an image. Canvas fit, zoom, panning and the Retina render
pixel conversion retain their existing policy. Larger Canvas handles and hit
areas share the original geometry centers, including Bézier anchors and grips.
