# Library replace transaction

This is a local transaction protocol, not part of `.wssbackup`. Backup v1 and its
writer retain their v1 contract. Tests use injected temporary roots and explicit preference domains. Startup recovery runs before normal runtime construction; confirmed restore resolves editors and drains runtime before publication. There is no merge, live reload or automatic relaunch.

## Caller boundary

`LibraryRestoreTransaction(root:preferenceDomain:).publish(_:quiescence:)` accepts
only a live `PreparedLibraryRestore`. It revalidates the complete staging and
claims it so `discard()`/a second publication cannot race the transaction. The
supplied root must be that artifact's support root. There is no archive reader in
this layer. A plan fingerprint, target seal and root object identities bind B.

`RestoreRuntimeQuiescence(callerGuaranteesQuiescentRuntime: true)` is an explicit
precondition, not proof that controllers stopped. The coordinator acquires exclusive maintenance, excludes backups and mutations, drains saves, stops runtime users and retains exclusion until publication/recovery and process exit. A nonblocking advisory lock under `.restore` excludes concurrent
transaction/recovery contexts on the same root; its inode is never unlinked.
MaintenanceCoordinator reserves the whole backup job (including its
SavePanel); the existing filesystem barrier still covers only snapshot acquisition.
For restore, the coordinator selects the archive and validates its Wupsy product marker
read-only before reserving maintenance. Ambient/unknown backup markers therefore
cannot create restore staging or change maintenance state. Full preparation reopens
and revalidates the archive after reservation; preflight never authorizes publication.

## Fixed slots and identity

The only replaced paths are, in publication order:

1. `Wallpapers/Packages`
2. `Wallpapers/Loose`
3. `Wallpapers/Media`
4. `Wallpapers/Web`
5. `Wallpapers/WSS`
6. `Wallpapers/NativeProjects`
7. `playlists.json`
8. `library.json`

The Wupsy root, unrelated siblings, external originals and caches are preserved.
A slots may be absent. B follows the complete fixed-slot contract: two metadata
files and six directories, which may be empty. A missing B slot is invalid.
`library.json` is published last. Nothing starts players or playlists.

The existing `.restore/staging/<local UUID>/` is retained, with `owner.json`,
`new/`, `old/`, `seal.json` and `.parents/`. UUID and ownership token are locally
generated. The journal stores no arbitrary absolute operation paths. Slot names
are validated against the exact allowlist, including order. Device/inode/type
identities and the exact marker bytes bind the support root, staging parent,
transaction, wallpaper parent and each A/B slot. Slot boundaries reject links and
special files. Descriptor-relative no-follow traversal and exclusive renames
prevent overwriting unknown destinations. Cleanup unlinks links without following
them inside a proven transaction only.

If A has no `Wallpapers` parent, a private candidate parent is created and identified
before the journal. Installing/removing this parent is itself an intent-journaled
rename, so rollback also restores its original absence. An existing parent and
unrelated children remain in place.

## Journal and persistence

`.restore/journal.json` version 1 contains local identity, owner bytes, target
fingerprint/seal hash, explicit preference domain, old/new preference envelopes,
fixed slots with A existence and A/B identities, completed moves, one pending move,
and phase. It is bounded to 128 MiB; malformed/unknown/contradictory journals fail
closed. Preference values retain the distinction between an absent key and an
existing value. The seal records exact target file paths, sizes and SHA-256.

Phases: `prepared`, `publishing`, `newStatePublished`, `rollingBack`,
`metadataCommitted`, `cleanupPending`, `cleanupComplete`, `rolledBack`,
`rollbackCleanupComplete`. There is at most one active journal.

Before prepared, B files/directories and transaction parents are synchronized.
A's current slot identities/existence and preferences are captured at this boundary,
not during long preparation. Each journal update writes an exclusive local
temporary file inside the owned transaction, fsyncs/full-syncs it, atomically renames
it to `journal.json`, then synchronizes both directories. Each slot operation:

persistent intent -> exclusive rename -> sync both parents -> persistent completion.

Recovery accepts either the pre-rename or post-rename identity arrangement for a
pending intent, never both/neither or an unknown object. It syncs/reconciles that
intent before deciding the next rollback move. Directory sync uses `fsync` and
`F_FULLFSYNC` where supported; unsupported full-sync on directories is tolerated
only after successful fsync. Actual write/rename/sync failures are fatal before
commit and preserve recovery data. Free-space estimates are not treated as proof.
A->old and B->productive are same-volume renames, without copying A or B. Device
mismatch is rejected before productive mutation.

## Preferences and commit

A narrow CFPreferences layer uses only the explicitly supplied application domain,
current user and any host. No standard UserDefaults or observable controller setters
are used. Each write synchronizes, the full projection is then synchronized/read
back and compared. This makes injected partial writes genuinely persistent.

The projection contains favorites, the six settings allowlist values, custom widget
package, independent widget enable/scale configuration, and widget all-displays.
`widgetPositions` is target-Mac state, excluded from the transaction write allowlist
and preserved byte-for-byte (including absence). Existing legacy widget layout
fields are retained while its portable all-displays field is replaced. `activeWallpaper`, `selectedWallpaper` and `selectedPlaylistID` are
removed; `manuallyPaused` is explicitly false. Playlist playback is already absent
from B's newly generated `playlists.json`. No backed-up UUID is activated.

After all B roots and the exact target file inventory/hashes have been confirmed,
`newStatePublished` is persisted. After the preference projection is confirmed,
`metadataCommitted` is durably published. Successful return from that journal write
is the logical total commit. The receipt identifies the transaction/fingerprint and
whether cleanup remains pending.

An ordinary precommit failure reconciles any pending rename, returns B slots to
new/, restores A slots from old/, restores an originally absent wallpaper parent,
restores every old preference including missing keys, and journals rolledBack.
Rollback is itself intent-journaled and can resume after another crash. A rollback
failure leaves the journal/old data; there is no aggressive cleanup fallback.

After a visible commit record, no error path rolls back A. If the commit rename
succeeded but its directory flush reported failure, the code first retries directory
synchronization; if durability remains uncertain it fails closed for recovery,
preserving B. A process/power crash can expose either atomic journal generation;
recovery follows the generation actually persisted. The presence of a durable
metadataCommitted or later phase always selects B, never A.

## Recovery and cleanup

`LibraryRestoreRecovery.inspect()`/`recover(quiescence:)` need only low-level file
and preference APIs, not Library/Playlist/Widget/Player controllers. WupsyEntry
now calls recovery before constructing WupsyApp or any normal runtime controller. Precommit recovery rolls back A; committed recovery
idempotently reapplies B preferences and continues cleanup. Unknown versions, roots,
tokens, slot arrangements or domains fail closed without guessing.

Committed cleanup first persists cleanupPending. Partial deletion of old/new can be
repeated while the proven root/owner remain. After all children except owner are
removed, cleanupComplete (or rollbackCleanupComplete) is persisted. This terminal
intent allows recovery after owner/root removal but before journal removal; only an
empty matching root or its absence is accepted. The staging parent is synchronized
before journal unlink, followed by a restore-directory sync. No sibling scan or
blanket `.restore` deletion occurs. Postcommit cleanup errors return success with a
pending-cleanup receipt; B remains authoritative.

Unregistered orphan preparation directories have no independent persistent ownership
registry. A plausible UUID/marker is not enough to authenticate them after a crash.
They are deliberately left alone; a still-live PreparedRestore can discard its own
unclaimed staging. A crash before prepared may also leave owned transaction setup
inside such staging. This conservative retention is accepted until an independently
verifiable orphan registry/policy exists.

## Deterministic verification

Tests use the actual writer -> reader -> prepared B. Crash checkpoints cover
prepared journal temp/publication, each A/B slot before/after rename (including
rename-before-completion), each preference write, pre/post total commit, cleanup,
rollback and recovery. New recovery objects use only persisted journal/files/domain.
Selected second crashes during rollback/cleanup verify idempotence. Ordinary I/O
faults additionally exercise automatic rollback and postcommit no-rollback behavior.
These simulate process interruption, not physical power loss or filesystem hardware
failure; durability relies on the macOS sync/atomic-rename contracts described above.

## Lifecycle boundary

WupsyStartup receives an explicit support root and preference domain. Its
read-only descriptor-relative probe distinguishes ENOENT from permission errors,
links and wrong object types (only the known system /var and /tmp aliases are
accepted). No journal means normal construction without creating restore folders.
Recovery must finish before the runtime factory is invoked. Any unresolved error
leaves the normal runtime unconstructed; a minimal AppKit error dialog ends launch.
No archive is selected or read. Benchmark context uses a separate temporary root
and domain; XCTest must inject a context rather than discover the productive one.

The app-wide MaintenanceCoordinator has separate whole-job leases and registered
high-level mutations. Backup and restore exclude each other; preparation still
allows ordinary editing. Freeze rejects new work. A task-local admission is valid
only while its owner is registered, allowing accepted async work and its nested
continuations to finish while drain waits. Deferred UI/drop completions without a
live admission must re-enter through the gate and are rejected after freeze.
A restricted editor-decision scope allows explicit close saves after freeze.
Cancelled and superseded runtime tasks are retained until actual completion.

The restore coordinator reserves restore, freezes normal admission, cancels/awaits
pending editor opens/creates with cancelPendingForMaintenance(), then call
MaintenanceCoordinator.drainMutations() before resolving editor decisions/saves.
This drain excludes registered runtime requests: a paused playlist request may
require cancellation by its runtime owner and must not block this early drain.
After editor approval, stop/drain playlist, then Library preparation/renderers,
then widgets, and finally call drain() to confirm every registered operation ended.
Library's terminal stop itself first drains accepted normal mutations, so their
final model/selection updates are not rejected by its terminal flag. If an editor
cancels before irreversible shutdown, cancelFreeze() allows the existing runtime
requests to resume after normal mutations drain; restartRequired still requires
all registered operations to have ended.
Editor resolution closes no window until every document approves; cancellation
restores interaction gates and retains explicitly chosen saves. Document close
awaits save, preview, canvas, resources and mask work for every origin, not only
drafts. Save As is followed through naming, commit and takeover/failure.
Library stop preserves selection; playlist shutdown does not save rotation state;
widget shutdown writes no preferences and preserves local positions.

Only after these boundaries may the caller acquire the final filesystem barrier
and assert RestoreRuntimeQuiescence. Never hold that barrier while awaiting editor saves or native project publication. All terminal flags are one-way; after irreversible
shutdown, V1 requires restart instead of rebuilding live controllers. Internal
restartRequired rejects new jobs, mutations, playback and editor/widget work;
normal Quit remains possible without resolving old A documents again.
LibraryRestoreCoordinator retains the job/barrier through publication, recovery and
until process exit. Native selection, plan summary and editor decisions precede
publication. A synchronous beforeClosing boundary runs after editor save decisions
and mutation drain, before any document closes: cancellation here retains editors
and explicit saves. Beyond it Cancel is disabled and shutdown is irreversible.
The app-owned progress panel survives closing the Library window. The Library scene
removes its content and dismisses itself after terminal drain; reopening is blocked.

A thrown publish always invokes low-level recovery while runtime remains stopped.
restoredA and retainedB select their respective quit/reopen messages. Recovery
errors or .none are conservatively unresolved: absence of a journal is not an
independent A/B receipt. This can also give the conservative message after an
ordinary failure already rolled A back and cleaned its journal. No format or
transaction boundary is changed to infer an outcome. Successful receipt is B even
if subsequent presentation fails; completion lies outside the publish/recovery catch.

Before handoff the UI discards only its live owned PreparedLibraryRestore, off main.
On entering publish it relinquishes cleanup ownership, including on error; recovery
alone resolves claimed paths. A preclaim error can therefore leave a conservative
unclaimed orphan, subject to the existing retention rule. Startup does not scan it.
Quit cancels/awaits reversible preparation (including dismissing native selection/
confirmation) or waits for terminal publish/recovery, then exits without A writeback.
No normal runtime controller reads B or is reconstructed in the current process.

## Safe manual acceptance

The product has no general isolated-root/domain launch option. Do not invent a
runtime override or use benchmark mode for restore. For controlled repeatable tests,
a separate macOS user account with its own home, Application Support and preferences
is recommended. Run dist/Wupsy.app
there, using only synthetic/redistributable test media. Keep the production user
logged out while switching accounts, and do not point the test account at its data.

1. Build a controlled B Library with two recognizable wallpapers, one playlist,
   favorites and portable settings/widgets; export B.wssbackup through Backup.
2. Build a distinct A Library in that same test account; start A wallpaper/widgets.
3. Verify Restore appears immediately below Backup. Cancel OpenPanel; A keeps running.
4. Select B.wssbackup; preparation runs without stopping A. Check date, counts and size.
5. Cancel confirmation; verify A, playlist, widgets and editors remain usable.
6. Repeat; also test preparation Cancel and an invalid synthetic archive.
7. Confirm Restore. Exercise dirty editor Save/Don't Save/Cancel, pending Open/Create,
   First Save and Save As using synthetic projects. Editor Cancel must retain A.
8. Repeat and approve all decisions. Observe the wallpaper stop, Library close,
   widgets stop, and Cancel disabled. No Library/editor/job can reopen.
9. Verify success dialog offers only Quit Wupsy. Quit normally.
10. Manually reopen the same build/account. Startup recovery precedes runtime creation.
11. Verify B wallpapers/playlists/favorites and projected settings/widgets; local widget
    positions stay local. No selected wallpaper/playlist is automatically activated.
12. Verify Backup/Restore and normal editing work again only in the new process.

GUI clicks and real desktop behavior require native manual acceptance;
automated orchestration/transaction tests do not replace that validation.
