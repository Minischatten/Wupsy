# Wupsy Library Backup v1

Backup, restore preparation, confirmed replacement and startup recovery are integrated into Wupsy.
A `.wssbackup` is an unencrypted, single-volume ZIP64 archive. It is a private
backup, not a redistributable wallpaper sharing format. Original media may retain
EXIF, URLs, credentials embedded in web sources, and other private metadata.

## Archive implementation

Wupsy links Apple's system `libarchive` through the public ABI declarations in
`Sources/CArchive/shim.h`. Some Apple SDKs omit libarchive headers; the shim declares
only the used public functions, and vendors no implementation. No new downloaded
Swift dependency, shell command, `Process`, or proprietary compression is used.
The system library supports macOS 14 / arm64. ZIP64 is explicitly forced and tested
on small fixtures. Entries use STORE (no recompression), appropriate for compressed
video/images and predictable disk estimates. Writer and seekable reader operate on
file descriptors with 1 MiB streaming chunks and cancellation checks. Memory for
entry inventories/ZIP directories scales with the bounded entry count; media bytes
do not scale RAM use. Existing WSS validation retains its bounded Data/Metal path.

Upstream sources and license:
- https://github.com/apple-oss-distributions/libarchive
- https://github.com/libarchive/libarchive/blob/master/COPYING
- https://github.com/apple-oss-distributions/libarchive/blob/main/libarchive/libarchive/archive_write_set_format_zip.c

libarchive is BSD licensed (principally BSD-2-Clause; individual source notices
control). Wupsy dynamically uses the OS implementation, rather than bundling it.

## Layout and version contract

```
backup.json
library.json
playlists.json
organization.json
settings.json
widgets.json
payloads/<Wallpaper-UUID>/source/...
recovery/<Recovery-ID>/...
```

`backup.json` identifies `wupsy-library-backup`, `backupFormatVersion: 1`,
`libraryRepresentationVersion: 1`, `playlistFormatVersion: 1`, and
`wssSceneSchemaVersion: 1`. These versions are independent. Unknown required
features or versions fail closed. Required features: `sha256`,
`portable-library-v1`, `zip64`. Creation time uses Foundation Codable Date semantics
(seconds since 2001-01-01 UTC). App/build strings are optional when unavailable.

`library.json` is an ordered portable array, not a raw copy of the runtime library.
Each record preserves UUID, title, kind, original ownership, managed relative location and native scene source. source mappings identify actual payloads. Native projects use source/ and entry scene.wss.json, with sceneSource nativeWSS and no playback mode. The current writer emits no native/ derived payload (native is nil, missingSource is false). Restore rejects missing sources, non-native scene metadata and non-nil derived payloads rather than converting them. Absolute external path/root strings are not emitted by the library representation; original user files can themselves contain private metadata.

`playlists.json` preserves saved collection v1 definitions/order, UUIDs, member
order, intervals, shuffle mode and persisted playback metadata. That metadata is
informational, never authorization to activate playback on future restore.
`organization.json` contains favorite UUIDs present in this library.
`settings.json` contains only profile, sceneRenderResolution, sceneFPS, conserve,
pauseOnBattery and allDisplays. `widgets.json` contains saved validated custom
HTML/CSS, independent widget kind/scale/enabled configuration and allDisplays.
Display positions/IDs, window/UI selection and login registration are excluded.
Missing optional custom widget code means the built-in starter is not copied.

The inventory hashes every metadata/payload file except backup.json itself,
which avoids a circular digest. `fileCount` includes backup.json;
`totalLogicalSize` sums the inventoried files (excludes backup.json). SHA-256 checks
integrity and consistency, not authenticity. Full verification reopens the finished
temporary archive, validates its manifest, exact file inventory, sizes, hashes,
paths and library/playlist/favorite relationships before publication.

## Saved state, ownership and completeness

WSS backups contain exact saved manifest bytes plus `referencedPaths` only.
Unreferenced immutable generations remain untouched in the live library but are
excluded from backup. Original packages, media and GIFs are copied byte-for-byte.
Managed Loose/Web project trees are preserved, without attempting dependency
minimization or downloading remote web resources. Existing native working projects
are authoritative user data and never regenerated or materialized for backup.

Missing wallpaper sources fail backup; an old derived copy is not a substitute. Invalid registered native projects and invalid managed UUID recovery projects fail. Valid orphan UUID projects under Wallpapers/NativeProjects without a current library UUID are stored as recovery, retaining their original UUID without inventing a library entry. Unknown non-UUID leaves and dot staging are excluded. Historical cache NativeProjects are excluded because ownership/provenance cannot be established; this limitation is recorded in manifest notes. Recovery payloads must pass the same native resource validation.

External single image/video/GIF files can be copied. External web project roots must first be imported into the managed library. External native WSS uses the validated referenced-resource closure, not a recursive copy of its entire directory. Current backups do not promote incomplete imported scenes.

## Snapshot and lifecycle

A process-wide counted lease coordinates persistent import, removal, rename, native save and Save As/First Save publication. The exclusive snapshot lease is acquired without blocking the main actor after pending mutations drain. New persistent library mutations receive a retryable error during snapshot; existing playback can continue.
Playlist definition changes also take a mutation lease. Playback-only playlist
state may continue changing; its saved value is copied during analysis and does
not affect definition integrity or stop rotation.

Favorites, settings and widget UserDefaults are copied by value on the main actor
at the exclusive boundary without suspension. Later preference edits cannot affect
this value snapshot; they need no long UI lock. Library files and saved playlist
definitions remain protected through analysis/copy. Once the independent staging
snapshot is complete, the lease is released before ZIP writing/verification.
Dirty editors, Undo histories and unpublished drafts remain unchanged and excluded.
Backup does not apply wallpaper, save editors, publish drafts or mutate preferences.

Snapshot uses exclusively claimed private temporary staging, copies rather than
hardlinks, detects source changes and validates WSS fingerprints. Cleanup operates
only on the owned staging inode. Destination staging is an exclusive random file
in the selected directory, accessed using a pinned directory descriptor. Existing
backup is replaced with a same-directory rename only after successful verification
and snapshot cleanup. Cancel/failure before publication preserves it. The final
rename is the commit point; cancellation after commit cannot undo publication.

## Limits and security

Central limits in LibraryBackupLimits:
- 1 TiB inventoried logical contents; 256 GiB per file;
- 100,000 archive files including manifest; at most 100,000 traversed directories
  per source tree;
- 32 components, 1,024 UTF-8 bytes per path, 255 bytes per component;
- 16 MiB backup.json and each generated metadata file.

Existing WSS/playlist decoder and resource limits remain active. The 512 MiB WSS
Save-As limit is not a library/media limit. Available-space checks are estimates;
actual I/O errors remain fatal. STORE archive estimation includes bounded header
and manifest overhead. The same-volume combination of snapshot and destination
can still exhaust disk despite separate preflight checks; failure preserves the old
backup. Paths must be NFC relative paths, without dot/empty components, backslash,
colon or controls. Case-fold/Unicode and file-vs-directory collisions fail closed.
Only regular single-link files are accepted; symlinks, aliases, special files,
xattrs, ownership and resource forks are not emitted. Extraction is restricted to private restore staging.


## Restore preparation

This implements the existing v1 contract without changing any format version.
`LibraryRestorePreparer.prepare()` returns a `PreparedLibraryRestore` containing
an immutable plan and an owned `new/` tree. It never publishes that tree or applies
preferences, activates a wallpaper, or creates a player/editor. Playlists preserve
definitions but omit playback. Preferences are validated value projections only.

The selected archive is opened with descriptor-relative, no-follow access and
checked for in-place changes. Before the seekable libarchive reader builds its
index, a bounded envelope scan reads ZIP/ZIP64 end records, fixed central headers,
names and extra fields, and checks local header/name agreement and non-overlap.
It bounds the index count and byte range, accepts single-volume unencrypted STORE
regular files only, and rejects ambiguous names and path collisions. This closes
the concrete pre-enumeration allocation risk: libarchive's seekable ZIP reader
allocates its central-directory entry structures before returning the first entry.
The scan performs no decompression or payload interpretation; libarchive still
reads payloads and checks CRCs, using the same streaming SHA-256/inventory engine
as backup verification.

`backup.json` is bootstrapped under 16 MiB before payload extraction. A small
bounded JSON structural scan rejects duplicate decoded keys (including escaped
spellings); Foundation remains the syntax/type decoder. All versions/features,
size totals, mappings and the exact archive inventory must validate first.
Metadata is bounded before buffering: library and widgets 16 MiB, playlists 1 MiB,
organization 4 MiB, settings 4 KiB. Library is also bounded by the manifest that
contains its records. Widget names use grapheme limits, so a smaller widget byte
limit could reject valid writer output. Organization can contain at most the
100,000-file inventory's worth of distinct UUID references. Existing WSS resource
and semantic validators retain their own limits. Payloads remain 1 MiB streams.

All restored wallpapers become managed under locally constructed UUID folders: WSS for native scenes, Media for images/videos/GIF, Web for web trees. Fixed transaction slots still include Packages and Loose as empty directories, not as supported payload categories. Recovery projects go to Wallpapers/NativeProjects/<UUID>, remain outside the Library and cannot collide with Library UUIDs. WSS resource closure must exactly match its declared references and pass the read-only loader. Unknown/removed effects and legacy derived representations are rejected, with no regeneration or migration.

Staging uses `.restore/staging/<locally generated UUID>/owner.json` and `new/`.
Its random in-memory ownership token, marker bytes, pinned device/inode and exact
parent identity must agree before validation or discard. Only private regular
0600 files and 0700 directories are created. Verified payloads move within staging
instead of duplicating large media. The final validator reopens the managed library
and playlists, checks exact file inventory, rehashes payloads and semantically
loads native WSS and recovery projects. No old absolute paths are persisted.
`discard()` is cancellation-independent and removes only that owned transaction;
unknown sibling contents are untouched. [The journaled replacement protocol](RESTORE-TRANSACTION.md) handles publication, rollback and startup recovery; its journal is local transaction metadata, never part of backup format v1.
Unregistered orphan staging is retained because a plausible marker alone
cannot independently authenticate ownership after process death.

Wupsy v1 is a fresh product format: `format = "wupsy-library-backup"`,
`backupFormatVersion = 1`. Ambient development archives and unknown product markers
are rejected before restore staging or maintenance; no conversion or migration exists.
