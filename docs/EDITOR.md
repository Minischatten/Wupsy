[English](EDITOR.md) | [Deutsch](EDITOR.de.md)

# Native editor

## Create or open

Create a native wallpaper in Wupsy or import a project folder containing scene.wss.json. Open the native wallpaper in the editor. Images and masks are user content; Wupsy does not supply personal reference wallpapers or convert external engine projects. An invalid project is an error, not a request to reconstruct missing files.

The layer list controls painter order. Add image, Rain or CursorTrail layers, reorder them, rename supported image layers, toggle visibility or delete layers while retaining a valid scene. Image transforms use logical canvas coordinates; image Add/Replace normalizes PNG/JPEG input to independently owned PNG data. Replacing an image preserves the layer's existing transform/effect semantics rather than automatically resampling its fields.

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

The static Edit Canvas shows image layout without effects, Rain or Trail. Live Preview renders the working native scene, using the same runtime as desktop playback. Pointer movement and preview time are not document edits. Parameter/structure changes can replace preview resources and clear transient trail history; pause/sleep/session gates do not rewrite the project.

## Save, Save As and close

Editing updates the working model. Save validates encoded JSON, referenced assets and loaded fingerprints, installs immutable assets first and atomically replaces scene.wss.json last. Save never chooses another desktop wallpaper; an already active matching UUID refreshes to the committed snapshot without changing playlist state.

Save As creates an independently owned managed project, limited to 512 MiB, with a new title/identity. Successful publication switches the same editor to clean B with empty Undo/Redo, leaving A and desktop/playlist references unchanged. Failed library publication may leave a complete unreferenced project; no automatic garbage collection is performed.

Closing resolves unsaved changes. Native backup captures saved state, not dirty editor drafts or Undo history. Restore resolves all editors and drains runtime before irreversible publication, then requires quitting/reopening. See [architecture](ARCHITECTURE.md), [backup](../BACKUP-FORMAT.md) and [restore](../RESTORE-TRANSACTION.md).
