# Flow resource ownership and session limits

Native vector fields and Flow regions use immutable, privately staged generations.
Editing never overwrites their original project files. The scene format and Flow
sampling/transport calculations are unchanged.

## Owners and release

The document strongly owns generations referenced by its current and saved models.
Each Undo/Redo action also owns the generation handles required by its model, rather
than only remembering file paths. Save/Save As snapshots and in-flight resource
operations retain their own handles. Their files remain valid until the last owner
releases them; private staging is then removed by generation destruction. Published
project assets are not deleted by this mechanism.

The session registry holds weak references. It reports all still-live generations,
including ones retained by a running operation after their Redo branch was discarded.
It does not itself retain every resource ever created. Batch registration occurs
only after the complete batch passes validation, so a failed candidate does not
enter the registry. Current/saved ownership is reconciled on model changes and
successful saves. PNG image/mask retention behavior is unchanged.

When a new edit discards a Redo branch, resources needed only by that branch can
be released. A successful direction-field change adds one Undo step, independent
of the number of field/region files. No-ops, cancelled and failed strokes add none.
The fixed product ceiling is **100 directional Undo steps**, possibly fewer under
resource pressure. Undo/Redo transfers the same directional classification to the
inverse action; it does not create a new user edit.

Each action has a distinct native UndoManager target and a weak bookkeeping entry.
Trimming removes an oldest contiguous prefix of the document's Undo timeline, ending
at a directional step. Full-model parameter/structure snapshots older than that cut
must go too: retaining them could resurrect skipped field states and pin their bytes.
Recent non-directional actions remain. Other UndoManagers and parameter-only editing
sessions do not receive a new global step limit. Native menu/button eligibility uses
the actual remaining UndoManager actions, with the existing interaction locks.

Saving preserves the retained history and is not an implicit history reset.
Closing the editor ends that session/history, as before; reopening uses the saved
native project with a fresh registry.

## Identical native content

Before allocating a new vector/region generation, the preparation actor checks
live session resources of the same kind against the complete encoded fingerprint
and then verified actual bytes. Only byte-identical immutable content can be reused.
Headers, dimensions, signed Float16 data and coverage remain part of this check.
Reused resources are not charged twice or re-registered. Different effects may
reference the same immutable resource; a later edit changes only its target slot.
No external path or coincident filename authorizes reuse.

This is session-local deduplication, not global project scanning, lossy compression,
resampling, quantization or a scene-format change. A no-op retains its existing
resource spelling, including PNG input where supported.

## Limits and transactional history cuts

The committed shared vector/region session limit remains **128 MiB**. The 100-step
ceiling is not a guaranteed minimum. Admission plans the smallest oldest prefix
needed for the step count and resource quota, without altering any native actions.
Current/saved model paths, retained action resources, reused candidate resources and
explicitly pinned save snapshots are protected. Shared bytes count once. Final batch
validation also counts live resources outside the planned discarded action paths.

Only metadata and paths are walked during this planning; old field contents are not
reencoded or decoded. Candidate content deduplication retains its existing byte
verification. There are at most 100 retained directional steps, though unrelated
recent document actions keep their previous behavior.

New candidate files undergo all writes, encoding, source/upload-budget validation and
source/staleness checks before any history is removed. Private transactional candidate
bytes are separately bounded by the existing 128-MiB working allowance and the
512-MiB overall staging ceiling (old live bytes plus new candidate bytes). Paint/region-distance
working allocations are bounded to 128 MiB; resource validation/preflight must succeed
before model adoption. Thus rollback
can temporarily keep old generations alongside the candidate, exceeding 128 MiB of
private vector staging; this is bounded transaction staging, not an increase of the
committed-history quota. Current plus retained history plus new registered content
must fit 128 MiB after the cut. No unbounded storage is introduced.

After asynchronous preflight, admission is checked again. Complete batch validation
and current ownership acquisition happen before cutting native actions. No suspension
or throwing work occurs between successful adoption, cutting the planned prefix,
registering the new Undo action and installing the model. A failure before that boundary
preserves the previous model and entire previous history, including Redo. Partial files
are removed by their owners. On success, discarded Redo is released normally and
unreferenced trimmed resources disappear when temporary transaction handles return.

A save snapshot has an explicit lifetime pin, shared across its value copies, so
its resources cannot be budgeted as evictable while a save is still using them.
If protected current/saved/snapshot bytes, other live owners or a single candidate
cannot fit, the change is still rejected without cutting history. Ending temporary
owners can make a later attempt possible. Saving/reopening starts a fresh history;
there is no automatic migration or silent save-time history reset.

## Failures and responsiveness

Direction finalization keeps internal typed evidence: paint versus adoption stage,
underlying error, failure category and retained vector bytes. UI messages do not
expose underlying project paths or image data. Budget and temporary-storage failures
have localized explanations; stale/validation/cancellation remain distinguishable
internally. Failed writes clean their own private partial staging; failed adoption
publishes neither a model change nor a partial batch.

Input stays locked only through CPU paint, source validation, bounded candidate
staging and atomic model/Undo adoption. It is unlocked before the animated preview
catches up. Exact-revision cached authoring feedback can supply the committed bytes;
otherwise the same paint worker computes them. No input queue or sleep is introduced.
Source reload may finish asynchronously; the existing bounded stroke capture accepts
one new stroke while that source loads. A still-uncommitted stroke retains its lock.

Directional validation preserves the source fingerprints, scene/schema checks and
native field/region/decoded-image upload budgets. Splitting a shared field into a
new ID must still fit the aggregate budget. Device-specific footprint probes create
only individual empty textures; no shader compilation, image upload, distance-map
construction or full preview occurs on admission. Runtime GPU preparation failures
remain preview errors and do not roll back accepted model data.

Authoring arrows/paint feedback never await document preview currency. Optional
in-stroke GPU feedback runs only against a current compatible document revision;
stale results are discarded using stroke, point-revision and document-revision
checks. Mouse-up drops pending optional requests without waiting for active GPU work.
That work retains its immutable inputs until it safely returns. Optional GPU failures
retain typed internal evidence and suppress further optional attempts for that stroke;
they do not cancel valid CPU authoring or report a failed data commit. A later stroke
may try optional feedback again.

The document preview still has one active job and one replaceable latest revision.
Only complete committed models enter it. Each active job strongly captures its
referenced generations and has an explicit resource-path lease, so history trimming
cannot evict source files in use. It does not capture the whole Undo catalog. On
completion, session/revision/closed checks permit publication only for the current
model. Old results never write a model or overwrite a newer preview. Pending states
can be skipped. After editing stops the latest revision is prepared; a current
preparation error is shown separately, and a later successful request clears it.

Save snapshots use the working model, independently of preview currency. Undo/Redo
and selection changes can run after data adoption while preview work is pending.
Closing signals cancellation and suppresses late publication; already executing
resource work keeps its inputs until return. The same rules apply to failures.
Paint/adoption/input-ready timing and CPU/source/upload-validation timing are stored
as scalar diagnostics; preview preparation has its existing separate timing. No
project paths or image contents are added to logs.
