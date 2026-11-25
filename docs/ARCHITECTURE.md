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

The managed WSS detail preview in the Library is live; Library tiles,
playlist rows and compact artwork previews use a bounded thumbnail rendered
at time zero. During a desktop transition, the still image provides coverage
until a Metal drawable actually presents. The presentation callback retires
the still and reports readiness. WSS animation starts its normal draw loop
and elapsed clock independently of that callback, including on an occluded
desktop where GPU frames can complete without a presentation acknowledgment.

### Apply outcomes

Library.apply starts an external WallpaperApplyRequest, whose outcome resolves exactly once. accepted means preparation and synchronous renderer startup completed for every current target display and ownership was handed to runtime; it does not promise a first visible frame or continued media health. failed covers preparation/validation/no-display/startup errors and stops partial renderer sets. superseded covers a newer apply, Stop, shutdown or caller cancellation; obsolete callbacks cannot affect successors.

An apply started under effective pause remains pending until resume/startup. For ordinary startup, pausing cancels the preparation generation while keeping the request pending. Display/quality rebuilds retain a pending startup request and never revise a completed outcome. `activeWallpaper` stores the last accepted UUID. Pending or failed attempts preserve it, while Stop clears it. The in-memory active target may still be preparing and is not acceptance evidence.

An eligible image/WSS transition keeps the previous renderers until the candidate is ready. Failed preparation leaves the previous selection and renderers in place. A pause supersedes an in-flight transition. While the transition is pending, runtime errors from outgoing renderers do not interrupt it or replace the candidate's result. Runtime errors from the accepted renderer follow playback policy and leave the completed outcome intact.

### Save integrity and failure receipts

The loaded basis hashes exact manifest and referenced asset bytes, including hidden references, and verifies root/managed UUID ownership. mtime-only changes and unrelated files are not conflicts. This is local conflict detection, not a general multiprocess compare-and-swap. No-op Save verifies the basis without normalizing on-disk JSON. One immutable N snapshot may finish while Working N+1 remains dirty; closed sessions ignore receipts.

The Store actor serializes save with removal and verifies current Library ownership; a retained folder alone cannot authorize saving a removed entry. Manifest publication uses an exclusive same-directory temporary, preserves security metadata, flushes/closes, rechecks the basis and atomically renames. Precommit failure preserves the old manifest; postcommit failure produces a committed receipt/warning, never rollback. Cleanup only touches its owned temporary. No journal or hardware power-loss immunity is implied by manifest saves.

Generation installation writes/flushed/closes an exclusive temp, publishes with exclusive atomic link and syncs the directory. Even identical unknown bytes or symlink destinations are collisions. Retry may reuse only the exact live generation's recorded inode in that project, with a matching fingerprint. Prepare the actually published resources and recheck ownership/basis/all references before manifest replacement. N never publishes N+1 generations.

Save As freezes a snapshot and blocks concurrent edit/Undo/Save/close resolution until completion; it does not implicitly save A. Naming requires nonempty single-line ≤256 characters and ≤1024 UTF-8 bytes, without truncation; duplicate visible names are allowed. All copies are bounded, fingerprint checked, physically independent, and validated before exclusive directory publication and again at the final location. The Library replacement rechecks its old identity/content; that operation bounds Library JSON I/O to 512 MiB. Postcommit takeover/preview failures retain B and the committed receipt rather than deleting it or creating another copy on retry. Successful takeover centrally replaces the old session/bindings in one NSWindow, carries preview time/pause/zoom/presentation, and resets pan, transform mode and local Trail history.

### Workspace, gestures and close

Session layer/effect IDs survive reorder/delete/Undo. Parameter controls resolve them to current indices; stale selections cannot edit a new occupant. Layer deletion requires an explicit current layer selection and more than one remaining layer; effect/empty selections cannot delete the parent. Undo restores the deleted layer/selection and Redo restores the resulting neighbor selection. Revert to Saved is an undoable restoration of the session's saved model, not a reload from disk. Autosave and reload-from-disk are absent.

The static canvas draws on demand, without a player/display link, capped at 2560 pixels on its longest edge. Canvas coordinates are independent of that cap and backing scale. Numeric zoom is 0.05…4; Fit is computed, and pan/zoom never dirty the document. Double-click a visible image to enter explicit transform mode; ordinary image selection has no transform handles. Visible Storm selection activates the same handles through a session-only position/direction/length/spread adapter; no transform object is persisted for Storm. Corner drag scales proportionally about the opposite corner, Shift at mouse-down chooses independent scaling, rotation is counterclockwise radians without snapping. Escape cancels an active gesture before leaving the mode. Focus loss/mouse-up ends one Undo transaction; field editors retain their own Escape semantics.

Image transform and opacity updates can reuse prepared textures when the rest of the model matches. Fog and Storm parameter updates at unchanged layer slots can reuse immutable prepared resources. A fog mask descriptor change requires fresh preparation. Storm cache keys invalidate changed geometry. Edits incompatible with prepared resources require full preparation. Compatible updates keep player/clock/context ownership. Preview uses a separate coalescing worker with session/revision stale-result checks and keeps the last valid preview until replacement. Full resource replacement preserves elapsed time and pause/visibility but resets pointer/Trail history. Direction-field input unlocks after validated model/Undo adoption, without waiting for preview; authoring feedback also remains independent of preview currency. Active preview jobs pin only their referenced generation handles and coalesce pending revisions. Save does not wait for preview. Enlarging preview transfers the same surface. Presentation is session-only.

Fog speed dragging keeps the thumb and readout in local SwiftUI state. The native
preview draws the latest transient drift with the prepared renderer and texture
when the preview revision is current. Paused and on-demand views coalesce redraws.
Releasing the slider commits the final X/Y drift as one document revision and one
Undo step. If preparation is already pending, the preview worker reconciles the
committed values with the other edits.

For animated Fog, Storm and Starfield, the editor renews the player when leaving
on-demand drawing or resuming after pausing continuous playback. This works
around a stalled MetalKit draw timer, including when a hidden animated layer is
shown again. Renewal reuses prepared resources and carries the playhead and
pause state. The Starfield workaround also applies when transferring a running
preview between windows.

Close routes share Save/Don't Save/Cancel, await in-flight Save and recheck later dirty work. Deferred AppKit termination resolves all sessions before desktop cleanup. Cancellation or save failure keeps sessions intact. Save/Save As/Revert/Close must not race an active/finalizing stroke; finish/cancel it first. Undo/Redo operates on immutable generations after the transaction ends.

### Scalar mask transactions

Supported target slots are Ripple, Clouds, Rain and Fog. Session/layer/effect identities locate a slot; paths are resources, not editable-target identities. Mask management and direct paint are distinct from parameter-only updates. Masks are scalar R8 with preserved UV scale; grayscale PNG encoding is decoded back to verify identical bytes, without color normalization. Image-oriented mask coordinates use the inverse layer transform; Rain uses its region geometry and Fog uses the full logical scene. Its Canvas tint applies the same vertical
envelope as playback using height and softness, with no animated noise. A first
direct stroke on unmasked fog reads a temporary white bitmap and publishes
its first generation only when the stroke changes coverage. Undo restores the
absent reference. The Canvas displays absent fog masks with a reusable 1×1
white sample, without allocating a bitmap or asset on selection. A fully black fog mask is validated and classified during
preparation without texture upload. The prepared classification suppresses its
draw, animation demand and effective-effect contribution.

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

## WSS performance measurement

Performance collection is opt-in per WSS player. The desktop renderer and
each preview player have independent session IDs. Reconfiguring a player
keeps its ID and replacing it creates a new one. An activation starts a fresh
collector. Deactivation and player stop detach it and reject late completions.
A desktop renderer or preview surface can carry opt-in across player replacements. Collection adds
no diagnostic callbacks, clocks, timers or memory queries to ordinary playback.
The existing completion and first-presentation handlers remain in charge of
resource lifetimes, errors and transition readiness.

A session snapshot contains the current player state, configured drawable size
in pixels and the actual texture size of the most recently submitted frame
in the current measurement generation, when available. The paused state describes the playback
gate. On-demand means playback is enabled for a static scene. Running means
continuous playback is requested. Failed records a reported render failure.
Preparing and system pause reasons remain with the existing playback owners.
None of these states confirms presentation.

Completion totals count successful Metal command buffers. A GPU sample
requires finite timestamps with a positive start and a later end. Its duration
covers the command buffer. GPU averages divide by the number of valid GPU
samples. These cumulative totals retain the stage 1 benchmark semantics.

### Frame measurement windows

An explicit performance snapshot closes the current measurement window and
starts the next one. Its elapsed time comes from the monotonic host clock
(`CACurrentMediaTime`). The caller can take a snapshot about once per second.
The player does not schedule sampling.

- **Target FPS** is the Metal view's configured preference.
- **CPU encoding duration** is elapsed host time around a successful
  `WSSStaticResources.encode` call. Drawable acquisition, playback-clock and
  pointer lookup, submission and failed or skipped encodes are outside the
  timing sample.
- **GPU completions per second** counts successful completion callbacks
  received during the window. **GPU time** averages only successful buffers
  with valid start and end timestamps. A late successful completion in the
  same generation counts in the receiving window.
- **Confirmed presented FPS** counts positive, finite Metal drawable
  presentation timestamps inside the window, divided by its elapsed time.
  A callback for a frame submitted earlier can count if its presentation
  occurred inside the current window. A timestamp older than the open
  window is discarded. Closed snapshots are final.

If any frames were submitted during the window or could still be pending at
its start, zero confirmations means presentation FPS is unavailable. A window
with no such activity can report measured zero. CPU and GPU duration averages
are unavailable without valid samples. These metrics describe different stages
of the pipeline, so their samples and rates can differ.

Each player has its own measurement session. Pause, resume, replacement of
prepared scene resources, and render-target or preview policy changes open a
new measurement generation. Stop or deactivation retires the sampler. Late
callbacks from an earlier generation cannot populate current frame windows.
Existing cumulative completion totals stay scoped to the activation for
benchmark compatibility. Frame windows hold fixed-size counters, with no
per-frame history, readbacks or GPU waits. CPU aggregation stays on the
main actor. Metal callbacks aggregate directly without scheduling a task.

Process footprint is the current process's Darwin `TASK_VM_INFO.phys_footprint`.
Failed or truncated queries yield an unavailable value. Metal allocation is
`MTLDevice.currentAllocatedSize` in bytes, associated with the device registry
ID. A device value can be shared across sessions and can overlap process
footprint on unified memory. Sample it once per device when reporting several
sessions. The reported device allocation and the existing WSS texture
subtotals describe different scopes.

### Diagnosis views

The Library’s three-dot menu opens one nonactivating AppKit panel. It starts
closed on every launch and remains visible when another app becomes active.
Only this panel has floating level
and the public AppKit `canJoinAllSpaces` and `canJoinAllApplications`
behaviors. It stays nonactivating and requests no Space switch. AppKit can
include eligible overlays in another app's full-screen Space. Visibility
still depends on the compositor and the other app's window mode and
layer. Exclusive display capture and higher-level surfaces, including some
games and protected content, can cover the panel. Its frame origin and disclosure are
local preferences. Restoring the panel clamps it to the retained display’s
visible frame or centers it on the fallback display. The selected display is
independent of panel placement. While open, display identity retains the
selection across a renderer replacement. Removing the selected display selects
the first remaining renderer, if available. Non-WSS desktop renderers show
the playback status with WSS frame measurements unavailable. Display
selection and position recovery were tested with simulated topology changes.
Physical multi-monitor configurations, including moving the panel between
displays and disconnecting a display, remain unverified in practice.

The Editor’s live preview has its own gauge button and a separately saved
disclosure. Enlarging and returning the preview moves the same diagnosis view
with its preview surface. If presentation recreates the preview player, the
diagnosis switches to that player. Closing the editor or turning the diagnosis
off releases its session. Closing the desktop panel detaches its selected
renderer and cancels its sampler. Regular quit closes the panel with the
existing playback cleanup.

Both views consume the existing snapshots about once per second. Play, pause,
replacement and other generation resets invalidate the displayed frame data
immediately. Expanded details count visible entries in the rendered scene and
effective prepared image stages and effect layers. A layer can count once as
a layer and once as an effect. Neutral stages, hidden entries and zero-opacity
image effects do not count as effective. Temporary weather and pointer activity
do not change the meaning of this count. The pixel dimensions of the submitted
drawable and the configured render target appear separately. The disclosure
label and icon share one keyboard- and accessibility-operable button.
Process memory (physical footprint), Metal memory (device allocations), and
process CPU usage appear below session values. On unified memory the two
memory readings can overlap and must not be added.

Process CPU uses successive public `getrusage(RUSAGE_SELF)` readings and
monotonic elapsed time. The numerator is user plus kernel CPU seconds.
One logical CPU fully used during the interval represents 100%. Concurrent
work can exceed 100%. The value describes Wupsy as a process, with no
attribution to a preview, display, or helper process. The first reading and
intervals without a valid pair are unavailable. In a VM it measures guest
process accounting.

Open, expanded diagnosis views share one on-demand resource sample per
second. The process CPU and footprint queries run once per interval, and
Metal allocations are cached once per device in that interval. Closing the
last expanded view clears the CPU baseline and cache. No resource query
runs with both details sections closed. Frame measurement continues for an
open diagnosis whose details are collapsed.

#### Utilization metrics and scope decisions

| Scope | Public interface and meaning | Reliability, compatibility and cost |
| --- | --- | --- |
| Wupsy CPU | Darwin `getrusage(RUSAGE_SELF)`, CPU-time delta over host elapsed time. | Available throughout Wupsy's macOS support range. Reliable process accounting, averaged over the actual interval. One shared syscall per sample. |
| System CPU | Public Mach `host_statistics` with `HOST_CPU_LOAD_INFO`; delta of user, system and nice ticks divided by the delta of all ticks including idle. | Available throughout the supported macOS range. Coarse aggregate across logical CPUs, 0–100%, with guest-wide figures inside a VM. One additional Mach call per sample and wrap-aware tick differences. Deliberately omitted because the diagnosis focuses on Wupsy. |
| Wupsy GPU | Metal command-buffer timestamps and optional device counter sample buffers. | Timestamps measure buffer duration. Hardware counters are device- and stage-dependent and do not provide a process-wide percentage. Counter sampling and resolving add GPU commands and collection overhead. No suitable public low-overhead process utilization interface was identified. |
| System GPU | Activity Monitor and Instruments expose diagnostics as tools. Public Metal counters instrument submitted work. | No suitable public API was identified for periodically reading total GPU utilization across apps and engines. Metal counter support varies by device and VM. The overhead of a compliant system-wide sampler therefore cannot be quantified from these APIs. |

Wupsy process CPU usage remains in the expanded diagnosis. The diagnosis
omits process and system GPU utilization because no suitable public APIs
were identified. System CPU and both GPU utilization scopes have no
placeholder rows. The existing GPU render duration keeps its original
meaning.

### Stage 4 resource comparison

The local comparison runs the actual desktop renderer, diagnostic panel, and
live preview host in an optimized XCTest process. It does not measure the
standalone app's cold-start footprint. Both sources were exported to temporary
directories. The historical comparison uses `af1cb94`, the last commit
before the opt-in collector, with the same desktop fixture and sampler. The
checks use synthetic wallpaper files and separate test preferences.

An external process samples `proc_pid_rusage(RUSAGE_INFO_V2)` once per second
for cumulative user and system CPU time, physical footprint, and interrupt
wakeups. On the test Mac the CPU counters used Mach units (`125/3` ns per
tick). A CPU-bound calibration matched process CPU time after conversion.
CPU utilization divides the change in CPU time by actual monotonic elapsed
time, with 100% equivalent to one logical CPU. Wakeups are whole-process
counters and do not identify individual timers or callbacks.

The comparison does not enable Wupsy's diagnostic counters for any off
condition. GPU durations, Metal allocations, frame times, presentation rates,
WindowServer cost, and energy are outside the comparable external data.
The comparison supports no quantitative conclusion about GPU performance
regressions.

On macOS 27.2.1 (Apple M4 Max, AC power) the fixed fixture was `WSS-Clouds-v2`. The desktop renderer
used one screen, Balanced, Standard resolution, a 2560 × 1440 drawable, and
30 target FPS. The editor reference and active runs kept the same preview
open with a 640 × 360 drawable and 30 target FPS; both detail sections were expanded in the active
condition. The same renderer instances were used across state changes.
Each condition had three 15-second windows after five seconds of settling,
plus a 12-second initial warm-up. Desktop rounds put A first and E last,
alternated the order of B and C in the second round, and measured the
editor series separately with the second pair reversed. The D results
below use a dedicated repeat after one readiness assertion in the first
harness found the preview paused before the settling period. The repeat
warmed the panel once before opening the preview and verified visibility,
unpaused playback, playback-clock advance, and stable drawable size at
the measurement boundaries.

The table gives medians of the three window averages with their ranges.
Deltas are medians of within-round differences versus A, or versus D-off
for D. CPU deltas are in percentage points of one logical CPU. Footprints
are for the entire measured process.

| Condition | CPU % (range) | Footprint MiB (range) | Interrupt wakeups/s (range) | Paired Δ CPU / MiB |
| --- | ---: | ---: | ---: | ---: |
| Historical desktop | 4.05 (3.39–4.50) | 305.56 (305.56–305.56) | 125.5 (124.6–126.1) | — |
| A · Desktop, diagnosis off | 4.49 (3.83–4.83) | 318.69 (305.92–319.05) | 125.9 (125.0–126.7) | reference |
| B · Desktop, compact panel | 4.57 (4.23–5.64) | 319.63 (318.36–319.64) | 126.1 (125.1–126.6) | +0.40 / +0.94 |
| C · Desktop, expanded panel | 4.98 (4.95–5.70) | 319.86 (319.28–319.97) | 125.1 (124.5–126.0) | +1.12 / +1.17 |
| E · Desktop, diagnosis closed again | 5.16 (5.02–5.31) | 319.05 (318.69–319.11) | 124.6 (124.6–125.4) | +0.54 / +0.36 |
| D-off · Desktop and editor, both off | 7.68 (6.75–8.45) | 344.70 (341.38–344.72) | 249.7 (249.5–251.1) | reference |
| D · Desktop and editor, both expanded | 8.99 (6.98–9.10) | 346.09 (344.65–346.73) | 250.9 (250.3–251.8) | +0.54 / +2.01 |

Fresh A was 3.83% CPU and 305.92 MiB, within the historical CPU range and
0.36 MiB over the historical footprint. Only one A window preceded first
use of the panel. Later A windows include a warmed UI process. The first
panel opening added 12.43 MiB above fresh A; 12.77 MiB of added footprint
was still present at the first E. The warm B and C windows added roughly
0.6–1.2 MiB over their paired A windows. The comparison cannot assign exact
bytes to the panel itself.

B added 0.09–0.81 CPU points versus A and C added 0.15–1.22. E also ran
0.48–1.33 points above its paired A windows, with fewer interrupt wakeups.
Because E always came later, the desktop data cannot separate diagnosis
cost from order effects and normal background variation. Paired D windows
added 0.23–1.42 CPU points and 1.39–3.27 MiB with the same editor preview
running in D-off.
These are local observations from short windows and one fixture.

For the lifecycle check, the desktop renderer and editor preview stayed
allocated while the harness cycled both diagnoses 40 times through compact,
expanded, and closed states. The 55-second trace during repeated interaction
ranged from 358.80 to 362.28 MiB. The closed-state footprint immediately
before the cycles ended at 358.55 MiB. In the 50-second closed-state
follow-up it stayed at 358.69 MiB, with 7.24% mean CPU versus 7.37%
before the cycle. All 40 panel objects were released, and
neither player retained a collector after a close. No continuing footprint
growth was observed during the measured interval. The source of the footprint
still held above a fresh process was not fully determined. Slower growth
under longer or different workloads remains untested.

Closing cancels the diagnosis sampling task, removes the desktop
screen-change observation or editor player callback, and detaches the
collector. In the off render path the optional collector remains absent, so
no diagnostic clock reads, presentation handlers, GPU timestamp aggregation
or resource queries are scheduled. This lifecycle check does not count
individual callbacks in a system trace. It supports the shutdown behavior
independently of the whole-process CPU and wakeup differences.

The historical and repeated editor harnesses passed. The initial harness
still completed every desktop window and lifecycle cycle despite the early
editor readiness assertion. The stock local suite passed with 53 tests,
zero failures, and one optional reference-fixture skip. Its strict Metal
presentation probe confirmed presentation on the local Mac. The resource
comparison did not cover macOS 26, VM, or physical multi-monitor setups.
The measured CPU and memory overhead of active diagnostics was accepted
without further optimization or functional changes.

### CLI benchmark output

`--benchmark … --report …` explicitly enables collection on the first
desktop WSS session before warmup. The report retains `sceneFrames` and
`sceneMeasuredFPS` for compatibility. Their meaning is now successful GPU
completions and successful GPU completions per elapsed second, respectively.
They describe GPU throughput even when no presentation is acknowledged. A
sample spanning replacement of the measured session is unavailable. The GPU
average uses valid samples only and the new `sceneGPUValidSamples` reports the
denominator. Missing values use JSON `null`. An uninterrupted sample with no
completions reports a frame count and rate of zero.

`sceneDrawableWidth` and `sceneDrawableHeight` retain the configured target
size. The new `sceneSubmittedDrawableWidth` and
`sceneSubmittedDrawableHeight` report the most recently submitted drawable
observed in the current measurement generation. `sceneMetalAllocatedBytes` reports device
allocation separately from process footprint and WSS texture subtotals.
Footprint summaries use successful samples only and report `null` when
unavailable.

The report also includes `sceneTargetFPS`, `sceneFrameWindowSeconds`,
`sceneCPUEncodingAverageMilliseconds`, `sceneCPUEncodingValidSamples`,
`scenePresentedFPS` and `sceneConfirmedPresentations`. The stage 2 window starts
after warmup and may be shortened by a measurement generation reset. The
existing GPU throughput and sample fields continue to use their original
benchmark interval. A missing presentation rate is JSON `null` even when
GPU completions are available.

After writing the report, the benchmark schedules `NSApp.terminate(nil)`
for the next main-run-loop pass in default mode and returns. In Wupsy 0.7.0,
the direct call from the SwiftUI benchmark task entered AppKit's modal
termination loop while the delegate's main-actor task was still waiting to
run. Scheduling the request outside that task lets the existing delegate
complete its normal cleanup and reply to AppKit. The scheduling applies only
to the benchmark.

Release-bundle verification on macOS 27.2.1 ran the synthetic
`WSS-Starfield-Shooting-Stars-v1` scene three times. Each process wrote a valid
JSON report with GPU and memory samples, confirmed pause and resume, and
exited with status 0. A separate launch without benchmark arguments used
isolated user data and exited with status 0 after a normal AppKit Quit request.

Virtualized GPU timings, allocations and dimensions describe the guest
environment. The documented macOS 26 CI run did not confirm presentation,
while the strict presentation test passed on a physical Mac with macOS 27.2.1.
This measurement path uses data availability and applies the same checks to
both OS versions.
