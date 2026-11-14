# Library reorder and accessibility acceptance

## Final acceptance, 2026-11-14

The maintainer confirmed completion of library drag-and-drop ordering and the
VoiceOver/accessibility corrections on the current development build.

| Check | macOS 26.6.2 (VM) | macOS 27.2.1 (Mac Studio) |
| --- | --- | --- |
| Native library drag and drop, manual | Passed | Passed |
| Arranged order survives app restart, manual | Passed | Passed |
| VoiceOver navigation and announcements, manual | Passed | Passed |
| Backup/restore including arranged order, manual | Not separately confirmed | Passed |
| Complete test suite, total tests | 1,220 | 1,220 |
| Complete test suite, failures | 0 | 0 |
| Complete test suite, skips | 11 | 11 |

The final full-suite results were reported by the maintainer after the
accessibility-test correction. The earlier failing diagnostic runs described
during development are superseded by these results. No additional complete-suite
run is required for this documentation/commit step. Manual backup/restore
acceptance is confirmed for macOS 27.2.1 only; no equivalent manual result is
claimed for macOS 26.6.2.

Manual VoiceOver acceptance is separate evidence from in-process accessibility
unit tests. Successful unit tests alone do not establish complete VoiceOver
navigation. This acceptance records a development checkpoint, not a publication
or release; version/build metadata remains unchanged.

## Regression checklist

For future changes, run the same development build on both supported test systems.
Use synthetic media in a separate test macOS account, as described in
[the restore acceptance contract](../RESTORE-TRANSACTION.md#safe-manual-acceptance).
The app has no general isolated-root launch option. Do not use the production
library or preferences. The checklist guides future regression coverage; the
confirmed results above do not imply separate execution of every edge case below.

- Open an existing test library: its initial order matches the former Newest view;
  no sort picker remains. A valid saved selection survives. Missing/stale selection
  selects the first visible item. New imports appear at the front.
- Drag from the thumbnail to both halves of cards, forwards/backwards across several
  rows. Resize the window to change the column count and repeat. Confirm the insertion
  bar matches the resulting order. Reach the last position using the trailing surface.
- With enough items to scroll, hold a drag at the top/bottom viewport edges, including
  while the pointer is stationary. Check scrolling stops on exit, Escape and mouse-up.
  Confirm the highlighted card under the pointer agrees with the final drop target.
- Search/filter to A C E from global A B C D E. Drop E before C: global order becomes
  A B E C D. Drop after the last filtered item: insert after that UUID, not necessarily
  at the global end. Change search/filter during a drag and verify the old drop is
  rejected. Empty results, self-drops, outside drops and Escape change nothing.
- While a move is pending (for example behind a large synthetic import), additional
  drops cannot commit. On a controlled write failure the original order remains and
  a localized error appears. Do not change permissions on production files.
- Verify single click/selection, double click/apply, favorite button, context actions,
  and keyboard/Delete focus. A drag must never apply/open a wallpaper or trigger a
  stray click after release. Repeat over the favorite overlay and title area.
- Drop a supported file from Finder: it imports and appears first. Library drags must
  not display the file-import overlay; playlist drags must not reorder the library.
- Check the playlist's available-wallpaper picker matches library order, while saved
  playlist membership, order and running playback remain unchanged by library moves.
- Quit/reopen: exact arrangement survives. Back up the arranged library, restore it
  over a different test library, quit/reopen as required: exact arrangement returns.
  Also restore a synthetic v1 backup created before reorder support.

Record OS/build, pass/fail and any gesture/scrolling differences for future runs.

## Drop handoff and persistence coverage

The internal library.json array is the persistent order, displayed in reverse.
No order preference, extra UUID list, migration or backup format change is needed.
Metadata edits serialize through MainActor publication so an asynchronous import
or native save cannot publish an obsolete array after a move. Failed persistence
preserves the published model and saved order.

The library-entry UTType declares public.data conformance in code and in the app
bundle. SwiftUI's native drag source offers copy, so the destination proposes
copy for the transient UUID payload; Library.move performs the actual permutation
without copying wallpaper files or adding entries. The existing onDrop targets
and LazyVGrid remain in place.

Regression coverage includes global and filtered order, invalid/stale drag
contexts, concurrent edits, persistence failures, restart selection and backup
round trips without format changes. Native integration tests cover type
registration, NSItemProvider/Transferable handoff, accepted AppKit drops and
persisted library.json. Temporary probes and diagnostic logging are not part of
the product. Earlier unsuccessful automated GUI drag attempts are superseded by
the maintainer's successful manual drag-and-drop acceptance on both systems.

## Editor focus and accessibility coverage

Effect selection only resigns an active editable text responder. List/canvas and
read-only text focus remain intact; valid input commits, invalid input continues
to block selection, and Undo/Redo behavior is covered by focused regression tests.

The Ripple toolbar tests retain structure checks and exercise modern increment
and decrement methods, checking the correct bound model value, refreshed AX state,
valid bounds and an unchanged other value. Each disabled action is checked
separately for unchanged model values.

macOS 26 exposes native slider cells without the expected SwiftUI AX identifiers,
normalized AX values, and action return flags that can be false despite a changed
binding. macOS 27 exposes SwiftUI AX nodes with identifiers and binding-range
values. The test helpers use public AX bounds and unambiguous synchronized native
cell identities instead of assuming one representation or a true return flag.
The runtime difference was reproduced using the same synthetic binaries on both
systems, independently of SDK version. No OS-version skips or increased timeouts
were introduced; legacy action lists are diagnostic only.

Before the final full-suite acceptance, targeted Ripple runs passed all five
cases on both systems, and combined Ripple/editor-focus runs passed all eleven
cases on both systems, with zero failures or skips. These focused checks and the
full-suite results complement the separate manual VoiceOver acceptance above.
