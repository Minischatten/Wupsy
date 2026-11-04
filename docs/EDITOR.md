# Native editor

## Create or open

Create a native wallpaper in Wupsy or import a project folder containing scene.wss.json. Open the native wallpaper in the editor. Images and masks are user content; Wupsy does not supply personal reference wallpapers or convert external engine projects. An invalid project is an error, not a request to reconstruct missing files.

The layer list controls painter order. Add image, Rain or CursorTrail layers, reorder them, rename supported image layers, toggle visibility or delete layers while retaining a valid scene. Image transforms use logical canvas coordinates; image Add/Replace normalizes PNG/JPEG input to independently owned PNG data. Replacing an image preserves the layer's existing transform/effect semantics rather than automatically resampling its fields.

## Image effects

Add Ripple, Clouds or Flow to the selected image. Effects run in listed order, may repeat and may be reordered. See [technical bounds/defaults](../WSS-EFFECTS.md), including the distinction between slider convenience ranges and valid stored values.

- **Ripple:** amplitude, wavelength, stretch, movement direction/speed, evolution, structure rotation, lateral detail and seed. Structure rotation controls the pattern; lateral detail controls displacement transverse to movement. Neither is a camera-perspective control.
- **Clouds:** intensity, density, scale, signed horizontal/vertical field velocity and brightness, plus secondary X/Y velocity when the scene already contains a secondary field. Secondary scale/influence, softness, shading and Clouds seed remain stored/inspected settings, without separate authoring sliders. Adding Clouds creates a black mask: paint the desired area or explicitly choose Full Image. Opening existing unmasked Clouds does not add a mask or secondary field.
- **Flow:** speed, strength and edge protection, with direction painting on the canvas. New Flow starts neutral with an empty binary region; it moves nothing until painted. Normal paint establishes area/direction, Neutralize retains area while reducing movement, and Option/Erase removes area and zeroes affected vectors. Coverage remains independent and is not painted by the direction brush.

Select an effect to inspect/edit its mask where supported. Scalar mask painting writes independent generations, never the original file. The selected overlay is editor state; it is not a persisted visual layer. Flow vector and region changes are adopted together or not at all.

## Rain and CursorTrail

Rain is a separate rectangular scene layer. Adjust region and rain controls; place it between images to occlude streaks with foreground content. New Rain uses three editable length/width profiles and density 150 (with a nonzero-count adjustment on very small canvases). Existing profile-less Rain can enable profiles explicitly; loading alone never adds them. The model constructor density 100 is separate from this editor insertion default. Density is an area-based parameter, not an exact total-drop count; edge padding and the scene instance budget also apply.

CursorTrail is a procedural layer controlled by the local pointer in live preview/playback. New trails use two colors and ageGradient; existing multi-color/sampleRandom configurations remain until an explicit two-color conversion. Controls include colors, spatial length, lifetime, width and **Kurvenauslenkung / Curve amount** (0…0.50, default/reset 0.15). Higher curve amount can overshoot corners; it is not temporal smoothing. Lifetime changes scale both fades proportionally. See [Trail](../WSS-TRAIL.md).

## Numeric fields and Undo

Numeric fields keep their displayed spelling when focused. Empty/incomplete text is permitted while typing. Return and successful focus loss commit valid, finite, in-range input. Invalid text keeps an error hint and does not change the document; Escape restores the latest model value. German decimal commas are accepted; direct input retains supported Float/Double precision.

Display rounding does not round persisted parameters. Focus without a text change preserves the original internal value even if the label is rounded. Slider/model updates refresh untouched fields; a modified draft remains editable while its cancellation baseline follows the newer model. Only real model changes enter document Undo/Redo. Save validates pending editing before publication.

## Canvas and preview

The static Edit Canvas shows image layout without effects, Rain or Trail. Live Preview renders the working native scene, using the same runtime as desktop playback. Pointer movement and preview time are not document edits. Parameter/structure changes can replace preview resources and clear transient trail history; pause/sleep/session gates do not rewrite the project.

## Save, Save As and close

Editing updates the working model. Save validates encoded JSON, referenced assets and loaded fingerprints, installs immutable assets first and atomically replaces scene.wss.json last. Save never chooses another desktop wallpaper; an already active matching UUID refreshes to the committed snapshot without changing playlist state.

Save As creates an independently owned managed project, limited to 512 MiB, with a new title/identity. Successful publication switches the same editor to clean B with empty Undo/Redo, leaving A and desktop/playlist references unchanged. Failed library publication may leave a complete unreferenced project; no automatic garbage collection is performed.

Closing resolves unsaved changes. Native backup captures saved state, not dirty editor drafts or Undo history. Restore resolves all editors and drains runtime before irreversible publication, then requires quitting/reopening. See [architecture](ARCHITECTURE.md), [backup](../BACKUP-FORMAT.md) and [restore](../RESTORE-TRANSACTION.md).
