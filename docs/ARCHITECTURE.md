# Native architecture and maintenance contracts

## Identity, data and isolation

ProductIdentity/ProductPaths centralize Wupsy's bundle/preference identity and Application Support/cache roots. The app does not discover Ambient data. Tests inject synthetic roots and isolated preference domains; they must not mutate the user's library. Native scenes, media and local web content are supported; external engine parsers/profiles and derived-project conversions are absent.

The native path is typed WSSSceneDocumentV1 → validated WSSScene → independently owned resources → player. [Scene format](../WSS-SCENE-FORMAT.md) is the persistence contract. Unknown fields/types/versions and unsafe resources fail closed, including hidden nodes. Runtime resource and pass budgets apply before rendering; identity stages do not skip asset validation.

## Document and resource ownership

The editor separates saved and working models, revisions, stable session layer/effect identities and resource catalogs. Session identities, selection, brush state, navigation, history, transient pointer samples and preview players never become JSON fields. Immutable image/mask/vector/region generations support Undo and stale-result checks. Shared originals are copy-on-write; only the edited target reference changes.

Image Add/Replace normalizes accepted image inputs to eight-bit RGBA sRGB PNGs with explicit descriptors. Scalar masks preserve linear scalar data and sampling/UV contracts. PNG vector fields become native data on explicit edits, not opening. Existing field dimensions and unrelated shared references remain unchanged. Region membership and vector changes are atomic document mutations, with one Undo step.

Generation ownership, fingerprint checks, bounded staging and resource preparation precede adoption. Asynchronous results must still match their captured revision/target identity. Cancellation, budget/preflight failure or stale work may not publish half a mutation. The editor's working asset catalog overlays staged generations on validated project assets without writing sources.

## Save commit points

Save encodes the typed model, validates those exact candidate bytes through native preparation, checks loaded manifest/referenced-asset fingerprints, installs exclusively named immutable generations and atomically replaces scene.wss.json last. The manifest replacement is the save commit. Failure before it leaves the prior saved document authoritative; complete unused generations may remain. No in-place overwrite of original image/mask/field/region bytes or automatic garbage collection is permitted. Undo can still reference unchanged older assets.

A save result must be reconciled with current editor revisions; later edits must not be marked clean accidentally. Normal Save retains document history. Matching active-wallpaper UUID refreshes to the committed snapshot; Save does not activate another wallpaper or alter playlist definitions.

Save As validates a self-contained independently owned project and exclusively publishes it before atomically persisting the new Library entry. The Library write is that workflow's commit point. It is limited to 512 MiB and copies referenced bytes, including session generations; old A is untouched. Successful takeover switches the same editor to B, clears Undo/Redo and marks B clean. Failed Library publication can leave an unreferenced complete B, without unsafe cleanup inference. Source paths/identities and desktop/playlist references do not silently follow B.

## Playback, apply and preview

Preparation and renderer ownership are separate from immutable document values. A superseded/cancelled apply must not commit stale selection or replace a newer player; retain tasks/resources until actual completion. Player stop releases its runtime ownership; immutable prepared resources may be shared within their documented lifetime. GPU commands retain in-flight resources until completion, including scratch-target leases. Never reuse an output as its own sampled input.

Image effect array order and layer painter order are independent; the
[shared stack contract](effects/COMMON.md#ordered-stacks) defines stage planning,
explicit input/bindings, intermediate budgets and final composition.
Optional Storm illumination wraps completed native composition in one bounded
per-player scene target and a final tone pass during active impulses only. The
original direct path remains authoritative for disabled/neutral/fallback frames.
Its separate two-slot leases follow GPU completion, and diagnostics include their
allocated bytes; see [Storm illumination](effects/STORM.md#optional-global-illumination-stage-2).

Preview and desktop share native rendering; the static editing canvas deliberately
omits effects/Rain/Trail. Pause/resume uses an explicit elapsed playback clock;
transient Trail simulation belongs to the player, not the saved document.

### Apply outcomes

Library.apply starts an external WallpaperApplyRequest, whose outcome resolves exactly once. accepted means preparation and synchronous renderer startup completed for every current target display and ownership was handed to runtime; it does not promise a first visible frame or continued media health. failed covers preparation/validation/no-display/startup errors and stops partial renderer sets. superseded covers a newer apply, Stop, shutdown or caller cancellation; obsolete callbacks cannot affect successors.

An apply under effective pause remains pending until resume/startup. Pausing cancels its preparation generation, not its external request. Display/quality rebuilds retain a pending request and never revise a completed outcome. activeWallpaper stores the last accepted UUID; pending/failed attempts preserve it, while Stop clears it. The in-memory active target may still be preparing and is not acceptance evidence. Later image/video/web/WSS runtime failures follow runtime policy without changing the completed outcome. Previous renderers are not retained during switching; failure can reveal the desktop. This is not a seamless-transition or rollback guarantee.

### Save integrity and failure receipts

The loaded basis hashes exact manifest and referenced asset bytes, including hidden references, and verifies root/managed UUID ownership. mtime-only changes and unrelated files are not conflicts. This is local conflict detection, not a general multiprocess compare-and-swap. No-op Save verifies the basis without normalizing on-disk JSON. One immutable N snapshot may finish while Working N+1 remains dirty; closed sessions ignore receipts.

The Store actor serializes save with removal and verifies current Library ownership; a retained folder alone cannot authorize saving a removed entry. Manifest publication uses an exclusive same-directory temporary, preserves security metadata, flushes/closes, rechecks the basis and atomically renames. Precommit failure preserves the old manifest; postcommit failure produces a committed receipt/warning, never rollback. Cleanup only touches its owned temporary. No journal or hardware power-loss immunity is implied by manifest saves.

Generation installation writes/flushed/closes an exclusive temp, publishes with exclusive atomic link and syncs the directory. Even identical unknown bytes or symlink destinations are collisions. Retry may reuse only the exact live generation's recorded inode in that project, with a matching fingerprint. Prepare the actually published resources and recheck ownership/basis/all references before manifest replacement. N never publishes N+1 generations.

Save As freezes a snapshot and blocks concurrent edit/Undo/Save/close resolution until completion; it does not implicitly save A. Naming requires nonempty single-line ≤256 characters and ≤1024 UTF-8 bytes, without truncation; duplicate visible names are allowed. All copies are bounded, fingerprint checked, physically independent, and validated before exclusive directory publication and again at the final location. The Library replacement rechecks its old identity/content; that operation bounds Library JSON I/O to 512 MiB. Postcommit takeover/preview failures retain B and the committed receipt rather than deleting it or creating another copy on retry. Successful takeover centrally replaces the old session/bindings in one NSWindow, carries preview time/pause/zoom/presentation, and resets pan, transform mode and local Trail history.

### Workspace, gestures and close

Session layer/effect IDs survive reorder/delete/Undo. Parameter controls resolve them to current indices; stale selections cannot edit a new occupant. Layer deletion requires an explicit current layer selection and more than one remaining layer; effect/empty selections cannot delete the parent. Undo restores the deleted layer/selection and Redo restores the resulting neighbor selection. Revert to Saved is an undoable restoration of the session's saved model, not a reload from disk. Autosave and reload-from-disk are absent.

The static canvas draws on demand, without a player/display link, capped at 2560 pixels on its longest edge. Canvas coordinates are independent of that cap and backing scale. Numeric zoom is 0.05…4; Fit is computed, and pan/zoom never dirty the document. Double-click a visible image to enter explicit transform mode; ordinary image selection has no transform handles. Visible Storm selection activates the same handles through a session-only position/direction/length/spread adapter; no transform object is persisted for Storm. Corner drag scales proportionally about the opposite corner, Shift at mouse-down chooses independent scaling, rotation is counterclockwise radians without snapping. Escape cancels an active gesture before leaving the mode. Focus loss/mouse-up ends one Undo transaction; field editors retain their own Escape semantics.

Transform-only reuse requires complete equality after restoring the previous transforms. Storm-only value updates at unchanged layer slots may also reuse immutable prepared resources and the player; its per-player cache keys invalidate changed geometry. Other edits perform full preparation. Compatible updates keep player/clock/context ownership. Preview uses a separate coalescing worker with session/revision stale-result checks and keeps the last valid preview until replacement. Full resource replacement preserves elapsed time and pause/visibility but resets pointer/Trail history. Direction-field input unlocks after validated model/Undo adoption, without waiting for preview; authoring feedback also remains independent of preview currency. Active preview jobs pin only their referenced generation handles and coalesce pending revisions. Save does not wait for preview. Enlarging preview transfers the same surface rather than creating another player; presentation is session-only.

Close routes share Save/Don't Save/Cancel, await in-flight Save and recheck later dirty work. Deferred AppKit termination resolves all sessions before desktop cleanup. Cancellation or save failure keeps sessions intact. Save/Save As/Revert/Close must not race an active/finalizing stroke; finish/cancel it first. Undo/Redo operates on immutable generations after the transaction ends.

### Scalar mask transactions

Supported target slots are Ripple, Clouds and Rain. Session/layer/effect identities locate a slot; paths are resources, not editable-target identities. Mask management and direct paint are distinct from parameter-only updates. Masks are scalar R8 with preserved UV scale; grayscale PNG encoding is decoded back to verify identical bytes, without color normalization. Image-oriented mask coordinates use the inverse layer transform; Rain uses its region geometry.

A CPU stroke freezes target revision/resource and settings. Per-texel maximum coverage makes one stroke independent of event count. With old value m0 and coverage c, paint is m0+(opacity−m0)×c (absolute target), erase is m0×(1−opacity×c) (relative reduction). Quantization clamps and rounds 255×value to nearest, ties away from zero. Falloff is 1−smoothstep(0.5r,r,d); tiny brushes use deterministic 4×4 footprint integration. Stamps use diameter/8 spacing with residual carry, include the final point and break outside segments rather than bridge them.

Cancel restores exact pre-stroke bytes; no-op finish creates no generation/history. Changed results encode/stage/validate asynchronously, then recheck session/revision/resource before one catalog/model/Undo adoption. Shared originals and other slot references are unchanged. Undo retains generations rather than replaying pointer events. CPU full pre/result R8 plus Float coverage storage can approach 192 MiB at the scalar pixel limit, excluding codec/renderer allocations; this is separate from the vector-paint 128-MiB work ceiling. Pending preparation pointer input is bounded; no per-pointer-event project file writes or encoded PNG publication occur.

## Library order and metadata publication

library.json and Library.items retain the same internal order; the canonical visible
order is its reverse. Imports and native First Save/Save As append internally.
Library.move expresses placement before/after a target UUID in visible order. The
Store reloads the current array, rejects missing/self/duplicate identities and
atomically writes only an actual permutation; wallpaper values stay unchanged.
No order preferences or backup format changes are needed.

LibraryEditQueue serializes import (one entry at a time), removal, rename, native
publication and moves through their MainActor model publication. This deliberately
includes each source preparation, avoiding a new split-commit API across import and
native publication. Batch entries release the queue individually; native thumbnail
preparation runs after release. A long single import can delay a move, but cannot
publish an old append after a move snapshot. Maintenance admissions cover queued
work; cancellation is checked on acquisition, while committed results always publish.
The existing Store mutation barrier still protects backup snapshots. Direct Store
calls are low-level/offline operations, not a second live Library writer.

The Library grid and playlist's available-wallpaper picker use LibraryOrder.visible;
there is no sort mode. Missing/invalid saved selection falls back to the last
internal item. Thumbnail drags carry an ephemeral context UUID and wallpaper UUID
using a separate library-entry UTType. Search, filters, page, visible membership
and maintenance changes invalidate that context. Card halves select before/after;
the trailing drop surface means after the last visible UUID, including filtered
views. Only Library.move receives the UUID command; no filtered array is persisted.
A controller rejects concurrent drops and invalidates accepted capabilities before
awaiting persistence. Native SwiftUI dragging handles click/drag thresholds; real
button/double-click/context-menu interaction remains a macOS GUI acceptance check.
A noninteractive AppKit bridge scrolls the existing clip view near its edges during
a hovered library drag, using common/event-tracking run-loop modes.
See [library reorder and accessibility acceptance](LIBRARY-REORDER-QA.md) for the
confirmed macOS 26.6.2/27.2.1 results and future regression checklist.

## Named playlists

playlists.json stores named v1 collection definitions and playback metadata. Only one playlist rotates; activation requires two distinct available library items. Double-clicking an active playlist does not restart it. Sequential and shuffle modes preserve the current wallpaper and remaining interval when switched. Shuffle consumes each entry once per round and avoids immediate boundary repeats; changing active membership/order starts a new round with Current consumed. Shuffle bags are not persisted.

Pause freezes rotation; Resume continues the remaining interval. Manual Apply/Stop disables rotation without deleting definitions. Failed/superseded ordinary changes stop rotation rather than retrying. Failed activation of another playlist can attempt one restoration of the previous activation/remaining interval; newer activation, Apply, Stop or Quit prevents stale restoration. Accepted activation is restored on launch with a fresh full interval, not a persisted shuffle bag. Definitions may be empty; deleting them never deletes wallpaper data. The former singular playlist.json is ignored, not migrated or deleted.

## Maintenance and filesystem boundaries

High-level maintenance admission and the filesystem mutation barrier solve different problems. Whole-job backup/restore leases exclude competing maintenance. Counted library mutations drain before a snapshot or terminal restore. Do not hold the final filesystem barrier while waiting for editor saves, dialogs or native publication. Deferred tasks need a live admission; cancelled tasks remain owned until completion. Terminal shutdown flags are one-way and require process restart, not reconstructed live controllers.

Paths are descriptor-relative/no-follow where required. Reject symlink traversal, special files, ambiguous Unicode/case names and destinations not owned by the operation. Cleanup is limited to proven ownership/token/inode scope; a plausible UUID or directory name is insufficient. Atomic rename is not a substitute for durable journaling when multiple roots/preferences must change.

[Backup format](../BACKUP-FORMAT.md) defines saved-state snapshots, inventories, resource closure, size limits and no private-data redaction guarantee. [Restore transaction](../RESTORE-TRANSACTION.md) defines fixed slots, intent journals, sync ordering, preference projections, rollback, postcommit cleanup and startup recovery. Recovery runs before normal controllers. Restore must not activate backed-up wallpaper/playlist state or write back old runtime state after publication.

## Numeric editing

Shared numeric controls keep a text draft separate from Float/Double bindings. Begin-edit must never overwrite the first deletion or expose a new unrounded spelling. Commit parses valid finite in-range data at Return/focus loss; unchanged text preserves original bits. Slider/Undo updates preserve modified drafts while advancing the restoration baseline. Escape restores the latest model; invalid drafts show an error without a model mutation. Only actual accepted changes register Undo. Locale formatting is presentation, not a storage conversion.

## Verification

Changes to these boundaries need focused failure, cancellation, stale-work and filesystem tests alongside successful roundtrips. Decoder/encoder tests must check unsupported data is rejected rather than dropped. Backup/restore tests use independent low-level recovery objects and injected domains, including interrupted publication/rollback/cleanup. Synthetic renderer cases provide repeatability; visual GUI acceptance remains separate. See [contributing](../CONTRIBUTING.md).

See [Flow resource lifetime](FLOW-RESOURCE-LIFETIME.md) for current/saved, history and async ownership, content reuse, the 100-step directional history policy, and transactional budget cuts.

## Managed-image draft replacement

First publication of a library-image draft may append (default) or replace an explicitly captured image receipt. The receipt contains the original Wallpaper record and raw source-byte fingerprint, but no array index. It is session-only. Renames/content changes/deletion/replacement conflict; moves are accepted. The Store rechecks the receipt at preparation, publication and immediately before the library rename, validates the final independent project, and replaces the current array index with a scene retaining the original UUID. The project directory uses the independent draft UUID. Old external and managed image files are retained. Duplicate titles remain legal.

Library JSON publication remains authoritative. The editor retains the committed receipt before takeover and the coordinator rekeys the same session to the published identity; close callbacks resolve the document rather than capturing the former draft ID. Successful adoption clears source provenance, so subsequent Save is an ordinary scene save. Replacement does not reserve or stop playback. After metadata publication, an inactive entry leaves all current renderers and playlist timing untouched. An active matching image is refreshed using the committed project's validated resources and the existing renderer path. Candidate windows stay hidden until every affected slot has started successfully and action generation, active record and display topology still match. Only renderer slots with the replaced UUID are exchanged; other slots and their callback lifetimes remain valid. Retired renderer lifetimes suppress already queued diagnostics as well as later events. No manual Apply command, playlist write or timer reset is emitted by this handoff. The app currently has one global wallpaper selection across its target screens, not independent per-display assignments.

Pending preparations are retargeted to the committed record while retaining the same external Apply request. Old preparation generations cannot finish into newer state. Paused requests remain pending until Resume. A stale image argument resolves to the current scene entry before a new Apply; preparation also rechecks the current record before starting renderers. A newer manual/playlist action, Stop, shutdown or topology change prevents an older handoff. Normal scene Save uses the same refresh path, including recovery after a prior image-to-scene handoff failure.

Library publication is not rolled back for desktop/thumbnail errors. Synchronous refresh failures retain all old affected renderers and return a committed warning. A changed display topology abandons candidates and warns; the next activation or normal display rebuild uses current metadata. Pending applies which had not yet displayed the image follow normal Apply failure semantics (the earlier desktop may already have been retired by the original Apply). Resource preparation/startup does not guarantee a first visible GPU frame or rollback after later runtime failure. Existing display/quality/pause/health policies remain authoritative.

Optional Starfield Milky Way rendering is a lazy immutable pipeline shared within
prepared resource families. It draws a bounded procedural region quad before
stars/meteors, with no texture target or simulation state. Parameter edits share
star populations and meteor pipelines; independent color transactions use the same
editor finish/Undo contracts. See [Milky Way](effects/STARFIELD.md#optional-procedural-milky-way-stage-3).
