# Vault I/O

How `Sources/Sempere` reads and writes a vault directory. Not normative:
`docs/format.md` is the format; this records the implementation choices on
top of it.

## Types

- `VaultManifest`: `vault.json` (§2), InkJSON conventions, pretty-printed.
- `BodyFraming`: `SMPR` ‖ `0x01` ‖ tag ‖ `gzip(JSON)` (§4). gzip comes from
  CZlib with `windowBits = 15 + 16`; the gzip header has mtime 0 and OS 255,
  so output does not depend on the platform. Unframing without the vault
  secret returns the body marked `verified == false`.
- `Vault`: a `.sempere` directory plus the identities it was opened with.
  Opened without identities it is locked (`isLocked`) and only lists
  names. Created with `identities: []` it is write-only: it holds the secret
  and can write revisions, but `canRead` is false, read paths throw
  `VaultError.noIdentities`, and `verify()` reports file contents as
  `notChecked`. Note-store
  methods (`write`, `readRevision`, `reconstruct`, `snapshot`, `compact`,
  `history`, `nextSeq`, `verify`) and identity files (`keys/`, §3.2) are
  extensions on it.

## Editing a note

`Vault.apply(_:to:deviceState:app:)` writes one delta of `Op`s as this device:
device id and hybrid clock come from a `DeviceState` file (saved before the
revision is written), the clock first observes every readable revision of the
note so the new ops win LWW, and `seq` comes from `nextSeq`. `NoteOps.newNote`
builds the ops for a new note (one page, all metadata fields, one `addTag` per
tag). Tag edits use `NoteOps.addTag` / `removeTag` / `setTags`, which take the
note's reconstructed state: a `removeTag` lists the instances it observed
(`format.md` §5.4.1); the app's `NoteWriter.append(to:building:)` builds them
from the note as read at write time.

The app does the same with its own `DeviceClock` actor (`NoteWriter.append`
for browser edits, `NoteWriter.write` for canvas autosave), so one process
ticks one in-memory clock over the state file instead of two writers
racing on it.

## Notebook paths

`NotebookPath` and `NotebookNode` (`Notebooks.swift`) implement the `/`
convention of `format.md` §5.4: `components` trims segments and drops empty
ones, `canonical` joins them back, `name(_:isWithin:)` compares whole
segments (`A/Bc` is not in `A/B`), `renamed(_:from:to:)` replaces a path
prefix, and `NotebookNode.tree` builds the sidebar forest with implicit
parent levels. The app renames or moves a notebook as one `setMeta` of
`notebook` per affected note (deleted notes included) and writes canonical
names for new edits; it never rewrites names it does not touch.

## iCloud Drive (app only)

`Sources/` reads a vault with plain `FileManager` calls and stays portable.
On iPadOS, a file iCloud Drive has not downloaded is only a placeholder: a
hidden `.<name>.icloud` stand-in (or, with newer File Provider versions, the
real name with status "not downloaded"). A listing skips the stand-ins, so an
evicted vault looks empty. The app (`Apps/Sempere/SempereApp/CloudVault.swift`,
`CloudScan.swift`, `AppModel+Cloud.swift`) therefore, when the vault folder is
ubiquitous (`FileManager.isUbiquitousItem(at:)`):

1. lists `vault.json`, `rewrap-journal.json`, `keys/*.age` and
   `notes/<id>/*.age`, mapping `.<name>.icloud` to `<name>` (other files are
   not fetched; unknown files are ignored anyway, §1);
2. calls `startDownloadingUbiquitousItem(at:)` on the real URL of every file
   whose `ubiquitousItemDownloadingStatus` is not `.current`;
3. polls (fresh resource values every 0.4 s) until each file that was only a
   placeholder is local, showing "Downloading from iCloud… n/m files" with a
   Cancel button. Files that are local but out of date are requested and
   not waited for. A download error fails the open with the file name; 90 s
   without any file completing fails it with a "check that this device is
   online" message. Cancel stops the wait (`CancellationError`, no alert);
4. reads (`Vault.open`, `summaries`, `summary`, `identityFiles`, the
   note an editor opens) inside an `NSFileCoordinator` coordinated read of
   the vault folder, and writes each delta (browser edits and canvas
   autosave, both through `NoteWriter`) inside a coordinated write of its
   `notes/<id>/` folder (vault creation: of the new vault folder), so iCloud
   sees and uploads the new revision files.

Attachments (`notes/<id>/att/`, `format.md` §8.1) are never fetched with
the note: the vault scan, `downloadNote` and `CloudVault.requireLocal` list
only a note's revision files, so an evicted, unlisted or missing `att/`
never makes a note look empty or pending (`docs/attachments.md` §4). When
the canvas shows a page, the `image` and `pdf` blobs its items reference are
requested without waiting (`BlobFetchPolicy`, `AppModel.prefetchBlobs`);
other kinds (audio, video, transcripts) only when used. Drawing an item reads
its blob through the model's `BlobCache` (`AppModel+Attachments`): that one
file is downloaded and awaited (`CloudVault.downloadBlob`), then read inside a
coordinated read that checks it is local (`CloudVault.requireBlob`) and
streamed through the vault's checks into a private temporary file (mode
0600, Data Protection `complete`), least recently used files dropped beyond
512 MB, everything deleted when the vault closes or changes. Meanwhile the
item shows a placeholder with a download symbol. Blobs are written
(`NoteWriter.addBlob`, `copyBlob`) inside the same coordinated write of the
note's folder as deltas. Before a blob is written or copied into a note, that
note's copy of it, if iCloud lists one, is downloaded first
(`NoteEditor.prepareBlobWrite`, `AppModel.blobWritePreparer`): blob names
depend only on the content, so an evicted copy is the same blob and is
reused, never written a second time beside iCloud's placeholder (blob files
are write-once).

Progressive loading: only the small unlocking files (`vault.json`, the
rewrap journal, `keys/`) are awaited before the unlock sheet; the notes are
not. As soon as the vault opens (still locked) `AppModel.startCloudSync`
starts passing over the notes. On iPadOS a file
iCloud has not downloaded may keep its real name and is *dataless*:
`ubiquitousItemDownloadingStatus` is "not downloaded", it allocates no
blocks, and no `.icloud` stand-in exists; both forms count as not local. A
note folder that lists no revision file at all is "not listed yet", never an
empty note: every note has at least one revision, and iCloud lists a
folder's contents after the folder itself. The app asks for the folder
(`startDownloadingUbiquitousItem` on it) and waits.

Each pass is change-driven (`AppModel.reconcile`; see "Opening a vault fast"
below): it lists the note folders by name, and only notes whose revision
names differ from those their shown summary was made from are checked with
iCloud (`ProgressiveLoad.pass(notes:)`, one state query per file), sorted
into *ready* (all files local: read at once) and *pending* (some file not
local), and pending ones requested at most 64 notes at a time, the note the
user selected first. A note first seen changed (or reported by the file
presenter, unless its names are the indexed ones: iCloud evicting a note's
files is reported too) is checked at once; notes already known to be arriving are
re-checked at most 64 per pass, in rotation (`cloudCheckLimit`,
`nextPendingChecks`), so N notes arriving over many passes cost
O(N + passes × 64) state queries, not O(N × passes) (a mass re-import can
change every note of a vault at once). A note whose files iCloud evicted but whose names are
unchanged is not pending: its row comes from the index and it is downloaded
only when opened (`downloadNote`). While locked, a device that already has an
index of the vault fetches nothing (the index will show which notes changed);
a device opening the vault for the first time requests every note, so they
download while the key is typed.

A folder that lists something but no revision (an `att/` folder: the
writer writes blobs before the revision that names them, so an import in
progress on another device, or one interrupted for good, leaves such
folders) is not a note yet and not pending (`ProgressiveLoad.Pass.orphans`).
A folder that lists nothing at all is pending for `cloudUnlistedTimeout`
(120 s) and then set aside the same way (`emptyNoteFolders`): neither is a
row or counted in the bar, so "Downloading" cannot wait on them forever.
Every pass still looks at them, and a revision that appears makes them notes.

Pending notes appear in the list with their indexed summary and a small
spinner, or, when nothing is indexed, with their row from the other
devices' published summaries (below), or else as "Downloading from iCloud…"
rows with a spinner.

**Listing before the notes arrive** (`AppModel+PublishedSummaries`,
`format.md` §12.5). Every device with a complete listing writes the
summaries of the notes it read to its own sealed file,
`summaries/<device>.sealed` (at most every 2 minutes, only when they
changed; it is the only device that writes that file, so it never
conflicts). A device on which notes are still arriving asks iCloud for
those files (not waited for) and, once they are here, lists the pending
notes from them: title, notebook, tags, dates and page text for search,
the entry whose revisions match the listing, else the one made from the
most revisions. Such a row is replaced when the note's own revisions are
read; it is never used to write (an edit downloads the note first). A bar under the list shows "Downloading from iCloud: n of m
notes", a progress bar and "n of m files" (`CloudSyncStatus`); it disappears
when no note is pending. While notes are pending the loop re-checks just
those every second (and lists every folder every 15 s); once settled it lists
every folder every 15 s, doubling while nothing changes, at most every 60 s,
for as long as the vault is open, so revisions other devices write arrive
without a pull to refresh. A file presenter on `notes/`
(`NotesFolderPresenter`) wakes the loop early for the notes it names. The
loop pauses while the app is in the background, restarts when the app
becomes active and on every reopen, and a pass of a loop replaced or paused
meanwhile publishes nothing. 90 s without progress shows a problem line in
the bar (not an alert) and the loop keeps trying; the line clears when files
arrive.

Listing (any vault, `AppModel+Loading`): unlocking only checks the key; the
note list is then read by a task the model owns (`startLoadingNotes`), so the
unlock sheet closes at once and no view going away can cancel the listing.
Summaries are read without stroke geometry, on up to four threads, in
batches of 24 (an eighth of the notes, at most 96, when many changed) that are
queued for the list as they finish (applied at most four times a second,
`queueListUpdate`); the bar under the list shows "Opening vault: n of m notes"
(or "Updating 640 changed notes: n done" when the list already shows every
note) next to the iCloud progress. On a reopen the indexed
summaries are shown before anything is read, and only notes whose revision
file names changed are read at all. Listings never overlap (`loadGate`), and
the cache file is written once per listing, not per batch, and while notes
keep arriving from iCloud at most every 20 s (`summaryCacheSaveInterval`;
also when they have all arrived, when the app goes to the background and when
the vault closes): every save re-encrypts the whole index. The list is usable
while it loads, so edits never decide from a summary not read in this session
(`verifiedNoteIDs`: one shown from an earlier launch's cache is re-read
first), a notebook rename waits until every note was read, a batch read
before an edit's own re-read does not merge over it (`summaryEpochs`), and a
listing only removes notes it saw before its scan (a note created meanwhile
stays, and stays selected). An
empty list always says why: loading (with the count), downloading from
iCloud, the listing failed (with Try Again), no search match, nothing in the
selected notebook or tag, or an empty vault (`EmptyListReason`).

Opening a note, and every browser edit of one (rename, tags, move, delete,
restore), first lists that note's folder afresh and downloads whatever is
missing, repeating until a listing shows every revision file local
(`downloadNote`; the detail pane shows "n of m files" meanwhile): a delta
must never be written on top of a partial log, nor computed from a
placeholder's empty summary. The editor's coordinated read checks again,
before and after loading, that every listed file is local
(`CloudVault.requireLocal`): a plain read skips `.icloud` stand-ins and an
unlisted folder reads as a note without pages, which the user would see as
a blank, editable note. Every browser edit's append (`NoteWriter.append`,
which picks the delta's `seq` and observes the note's clock readings) runs
the same check inside its coordinated read and writes nothing when a file
is not local. A note that cannot be made local is shown as an
error with Try Again in the detail pane, never as a blank canvas. Renaming
a notebook waits until no note is pending.

Every reload (pull to refresh) repeats this, so revisions other devices
synced since appear as placeholders, are fetched, and then read. Vaults
outside iCloud skip all of this: no scan, no coordination.

### Background sync (iOS)

Locking an iPhone or iPad mid-sync does not stop the sync
(`AppModel+Background`, `BackgroundSync.swift`):

- **A sync in flight finishes.** When the app goes to the background with
  notes still downloading or listed as placeholders (`syncInFlight`), the
  loop keeps running under a `beginBackgroundTask` assertion and pauses
  once nothing is pending (`finishBackgroundSync`). The summary cache
  is saved when the app leaves the screen and again when it settles.
- **When iOS takes the time back** with notes still pending (the expiration
  handler, `backgroundTimeExpired`), or gives none, the loop pauses and a
  `BGProcessingTask` (`io.github.anthonytw.sempere.sync.processing`,
  network required, no external power required) is requested to continue.
- **Otherwise** a `BGAppRefreshTask` (`…sync.refresh`, not before 15
  minutes) is requested whenever the app leaves the screen with an iCloud
  vault open, so revisions other devices wrote are fetched and read before
  the app is opened again.
- A scheduled task runs passes over every note folder
  (`runScheduledSync`, `cloudPollInterval` apart) until nothing is pending
  or iOS takes the time back (SwiftUI's `.backgroundTask` cancels it; it
  also completes the task), then requests the next refresh.

What iOS does not allow, so the app cannot promise it:

- Background time after leaving the screen is short (about 30 seconds on
  current iOS) and is not guaranteed; a large first sync does not finish in it.
- Scheduled tasks run when iOS decides: it weighs battery, charging, network,
  thermal state and how often the app is used. A refresh gets about 30
  seconds; a processing task a few minutes, usually while charging and idle.
  Background App Refresh switched off (Settings ▸ General, or for the app),
  Low Power Mode, or force-quitting the app from the app switcher stop both
  until the app is opened again. The simulator runs neither unless debugged.
- They sync only a vault that is still open in the suspended app. A task that
  launches the app afresh (iOS terminated it meanwhile) finds no unlocked
  vault, since the key is behind Face ID, and ends at once; the next launch
  syncs as usual.
- iCloud Drive itself keeps downloading files that were already requested
  while the app is suspended; what stops is the app asking for the next
  window of notes and reading the ones that arrived.

The Mac (Catalyst) keeps apps running when their windows are in the
background, so it schedules nothing.

## Other Files providers (Proton Drive) (app only)

Privacy first: the only cloud providers the project targets are iCloud Drive
(the system's) and Proton Drive; others may work through the same code but
are not tested on purpose. A vault in a provider's storage is opened like any
picked folder (`VaultLocator`, a security-scoped bookmark), and what happens
next depends on how the provider presents its files.

**Code paths that assume local files:**

| Path | Assumes | With a provider |
| --- | --- | --- |
| `VaultLocator.resolve`, `FolderAccess.check` | the picked folder lists its files | a provider that has not listed the folder yet makes a vault look like a plain folder ("not a vault"); try again once Files shows the contents |
| `VaultBookmark` (recents, backups, quick capture) | bookmarks of the folder resolve later | a provider that renames or re-creates its root gives a stale bookmark (refreshed) or a dead one ("choose it again") |
| `CloudVault.download` / `ProgressiveLoad` / `requireLocal` | files report a downloading status (`ubiquitousItemDownloadingStatus`), placeholders are `.<name>.icloud` or dataless files | used only when the folder is ubiquitous (`isUbiquitousItem`): iCloud Drive and replicated File Provider extensions (every `~/Library/CloudStorage` provider on a Mac) report it; then `startDownloadingUbiquitousItem` and the dataless check apply unchanged |
| `CloudVault.coordinatedRead` / `coordinatedWrite`, `NoteWriter(coordinated:)` | — | a provider fetches a file it holds only remotely for a coordinated read, and sees a new file through a coordinated write |
| `NotesFolderPresenter` | a file presenter hears of other devices' revisions | the same for any provider that coordinates; otherwise the list changes only on reload (pull to refresh) |
| `Vault` writes (`rename(2)`, `link(2)` for blobs, `fsync`) | a POSIX file system | File Provider storage is a local file system (APFS); `link(2)` falls back to rename where refused (above) |
| Error texts in `CloudVault.CloudError` | iCloud | they name iCloud Drive even for another provider (only shown when a ubiquitous provider stalls or fails a download) |

**Provider storage is coordinated** (`StorageLocation`): a vault whose path is another app's
provider storage (`~/Library/CloudStorage/<Provider>-…` on a Mac; a shared
app-group container or `File Provider Storage` on iPadOS) is treated like an
iCloud vault for coordination even when it does not report its files as
ubiquitous: every read and write is coordinated, so a non-replicated provider
fetches and uploads what the vault needs. Download requests and the
downloading status stay off for such a folder (there is nothing to wait
for); a ubiquitous provider takes the whole iCloud path. Vaults in
the app's own container (on this device, WebDAV copies) and on external
drives are not coordinated. `StorageLocationTests` pin the
classification.

**Verified** (without a device): the classification of iCloud Drive, Mac
`CloudStorage` provider, iPadOS app-group and app-container paths; that the
iCloud path keys on `isUbiquitousItem` and so already covers replicated
providers; that coordination is a no-op cost for local files.

**Not verified; needs a test on a device** (with
`SEMPERE_DEBUG_PROBE=1`, which logs how the files present, never names):

1. Proton Drive on iPadOS: whether its Files location lets the folder picker
   choose a folder at all (the location is reported to be unavailable while
   Proton's app lock (PIN or Face ID) is on, and that some folders fail to list),
   whether it opens in place with write access, and whether its files report
   `isUbiquitousItem`.
2. Creating a vault there, writing notes, quitting, reopening from Recents
   (bookmark), and a second device seeing the notes after Proton syncs.
3. Proton Drive for Mac (`~/Library/CloudStorage/ProtonDrive-…`) with the
   sandboxed Catalyst build: open, write, evict a note in Finder ("Remove
   Download") and reopen it (dataless path).
4. A blob write (`link(2)`) in Proton's storage on both platforms.

If 1 fails, Proton Drive on iPadOS cannot hold a vault through Files, and the
alternatives are iCloud Drive or a WebDAV server (above).

## Opening a vault fast (app)

The note list is shown from a persistent local **index**: the encrypted
per-device summary cache (`SummaryCache`, `format.md` §10) in Application
Support, never in iCloud. It holds each note's summary (title, tags,
notebook, deleted flag, counts, newest time, and whatever `NoteSummary` gains,
such as recognized text for search) and the sorted revision file names it was
made from. On a reopen it is decrypted and shown as it is, before any note
folder is looked at (`openSummaryCache`, `Perf` phase `index.load`).

Keeping it current (`AppModel.reconcile`, `VaultIndex.swift`):

1. **Enumerate by name** (`VaultEnumeration`, phase `reconcile.enumerate`):
   one directory listing per note folder, iCloud placeholders mapped to
   their real names, no file read, no iCloud state asked.
2. **Diff** (`IndexDiff`): revision files are write-once and named by
   `(hlc, device, seq)` (`format.md` §5), so a note whose names equal those
   of its shown summary is unchanged: nothing is downloaded, coordinated or
   decrypted for it. Changed and new notes are read; notes whose folder is
   gone leave the list (only notes listed before the pass, so one created
   meanwhile stays).
3. **Download and read only what changed** (phases `reconcile.download`,
   `reconcile.coordinate`, `reconcile.read`); `indexedNames` records the names
   each summary was made from.

### Summaries of a changed note

A note that changed since its summary was cached is read in full once, and
its reduction is kept in memory next to the cache (`SummaryCheckpoint`, at
most `SummaryCache.checkpointBudget` strokes, items and pages over all notes,
least recently used first out; never on disk, and never for notes listed for
the first time). When it changes again by gaining files only, just the new
files are read and merged into that reduction (`NoteReducer.advance`), so an
edit or a remote arrival costs one decrypt instead of one per revision. The
reduction stands for the old files as a snapshot that includes them all
would (`format.md` §5.3), so the merge is used only where the result is
provably the full reduction's: every new file is a delta ordered after every
reduced revision and recorded stamp, none is already covered, none re-adds an
id the reduction saw go or replaces a stroke that is not live, and none is an
orphan. Anything else (a snapshot, a compaction, a file gone, a delta from a
device whose clock is behind, an unreadable or newer revision) reads the note
in full. The summary is then identical; the kept state may hold more stroke
tombstones and lineage records than a full reduction, as a compacted vault's
snapshot would, which no summary field reads (`IncrementalSummaryTests`,
`MergeTests.testIncrementalReductionEqualsReconstruct`).

Passes run when the vault opens, when the app becomes active, at the loop's
idle pace and, for the notes named, when the file presenter reports a change.
Every pass waits for the index to be loaded first, so it never mistakes an
unloaded index for a vault where everything changed. A pull to refresh also
re-reads notes the index file does not hold (a summary with a problem).

A **full validation** (`validateVault`, phase `reconcile.validate`) asks
iCloud for the state of every file (slow on a device: one round trip per
file), refreshes out-of-date local copies, reports download errors in the
bar and drops index entries of notes that are gone. It runs at background
priority, outside the listing lock, once the list has settled and then every
30 minutes, and never blocks the list.

**List updates** are batched and throttled: queued summaries are applied at
most every 250 ms (`listUpdateInterval`) as differences (`NoteListDiff`: a
summary whose title order is unchanged is replaced in place, others are
removed and merged in; no re-sort), and `visibleNotes`, `tags` and
`notebookTree` are computed once per change of the list or the filters
(`DerivedLists`), not on every render. An edit's own re-read is applied at
once and supersedes anything queued for that note. The list stays a lazy
SwiftUI `List`.

## Opening a note fast (app)

- **Fast decoding.** A revision's point arrays are parsed by a hand-written
  exact reader (`FastRevisionDecoder`) instead of generic `Codable`
  decoding; the JSON is unchanged and anything unusual goes through the
  ordinary decoder.
- **Drawing cache** (`DrawingCache`, `format.md` §10.1): per note version
  (note id + sorted revision file names) a layout (the note without stroke
  geometry) and each page's PencilKit `dataRepresentation`, sealed under a
  key derived from the vault secret, in `Library/Caches/Sempere/Drawings`.
  Opening a note lists its folder's names; when that version's layout is
  cached the editor opens from it at once (`NoteEditor.isPreparing`: shown,
  not editable) and the shown page's drawing comes from the cache, while the
  revisions are read in the background. Once read, every cached drawing
  shown is checked against the strokes (`DrawingPreparation.matches`: count,
  texture seed from the stroke id, ink, points, ends, transform); a match
  becomes the page's ledger without any conversion, a mismatch is replaced
  by the real page (`canvasGeneration`) before anything can be drawn.
- **On a miss** the page is converted off the main actor, the strokes on
  screen first (`DrawingPreparation.convert(visible:)`, shown as soon as
  they are ready, drawing disabled until the whole page is in), and stored
  in the cache afterwards. Closing a note that was edited stores its new
  version (layout, unchanged pages as shown, changed pages converted in the
  background) and drops the old one.
- The cache is limited to 200 MB (`UserDefaults` key
  `Sempere.drawingCacheMegabytes`), least recently used files first. Opening
  it deletes every other vault's folder (and this vault's under an older
  secret); closing the vault deletes its folder.
- **Attachments.** Three caches keep them across note opens and launches, each
  per vault secret and deleted when the vault closes:
  - `BlobCache` (`Library/Caches/Sempere/Blobs`, 512 MB, `Sempere.blobCacheMegabytes`):
    the decrypted, verified blob files PDFKit and ImageIO read. File names are
    keyed (`format.md` §10.1); a file left by an earlier launch is hashed again
    before use (`adopted`), never decrypted again. Not on a Mac: there files
    are not encrypted at rest, so quitting deletes them (`purgeAtQuit`), a launch
    deletes what a crashed one left before any vault opens (`purgeAtLaunch`),
    and a reopened PDF is decrypted again (its preview still shows at once).
    Recordings, clips and transcripts are never kept (`BlobCache.isTransient`):
    deleted when nothing plays or reads them, and at the next launch if a
    session was killed first.
  - `RenderCache` (`Library/Caches/Sempere/Renders`, 256 MB,
    `Sempere.renderCacheMegabytes`, plus 96 MB of decoded images in memory):
    image items as drawn (`ItemRendering`), and one preview bitmap per PDF page
    item at the unzoomed screen scale. A PDF page shows its preview at once,
    before its blob is opened, and the tile layer draws the sharp page over
    it. Files are sealed like the drawing cache's.
  - The page's tiles themselves are Core Animation's and are not kept: they
    are redrawn from the open PDF at whatever zoom the page is shown, which is
    why the preview, not the tiles, is what persists.

## Changes from other devices while a note is open (app)

A note open in an editor takes revisions written elsewhere (another device
through iCloud Drive or any other sync, the CLI, this device's browser
edits) in place, without being reopened (`AppModel+RemoteMerge`,
`NoteEditor.mergeRevisions`).

- **Detection** is the change-driven listing (above): each pass lists the
  note folders by name, and an open editor whose folder holds a revision file
  name it has neither read nor written (`NoteEditor.knownRevisionNames`) gets
  a merge. In iCloud Drive the file presenter wakes the sync loop for that
  note, so a delivered revision is merged within a poll interval. A local
  vault is listed again on a reload. At most one merge runs per note.
- **Before reading**, every revision of the note is made local
  (`downloadNote`); the editor never writes while one is missing. The merge
  waits while a canvas is mid-stroke or mid-erase (at most `inkWaitLimit`,
  30 s, then it gives up and the next listing tries again: a canvas that never
  reports a stroke's end cannot stall the note's merges), then saves what is pending
  (one delta through the editor's `NoteWriter`, as autosave does) and reads
  the note again. A save that starts during that read (autosave, a page
  gesture) makes it read again (`writeEpoch`), since its strokes would
  otherwise look removed elsewhere. A note with an unreadable revision is not
  merged (tried again when its names change); a read-only editor (Recently
  Deleted, unreadable revisions) is reopened instead.
- **Reading only what is new**: only revision files the last read did not
  decode are decrypted (`read(reuse:)`), and from the second merge on only
  the new revisions are reduced, onto the note as the last merge left it
  (`ReducedNote.updated(with:)`, off the main actor), which also names the
  pages they changed. That is done only where it is exact: deltas that sort
  after every revision already reduced, none covered by a snapshot, holding
  only stroke adds and removes, page order, recognition and paper of a live
  page, meta and delete/restore, no stroke id seen before, no second
  replacement of one stroke (§5.6.1), and registers whose stamp is older.
  Anything else (a late arrival, a snapshot, a compaction, a page or item
  op, tags) reduces every revision again, as a fresh read does.
  `ReducedNoteTests` compares both over random interleavings of several
  devices.
- **Applying** is synchronous on the main actor, so no canvas can report a
  drawing in between. Per page, `StrokeLedger.mergeStored` takes the merged
  strokes as what is on disk and keeps what is pending here (strokes drawn
  since the save stay live on top, unsaved erasures stay erased): only that
  is ever written afterwards, never the other device's adds or removals (no
  echo). Canvas strokes are reused where every stored stroke they stand for
  is still live; only new strokes are converted. Every canvas showing a page
  whose ink changed (`RemoteInkView`) shows the merged drawing at once at the
  same scroll and zoom, and drops that page's undo steps (an older undo could
  put back a drawing without the other device's strokes and so erase them);
  other pages keep theirs. Items, papers, page order and additions or
  removals, recognition, meta and recordings are taken as merged; the item
  layer, text boxes and the selection follow the editor's pages. An infinite
  page that grew here and is not saved keeps its height. Concurrent edits are
  decided by the format (`format.md` §5.3, §8.2.2): the editor shows what
  every device reconstructs.
- **Shown**: "Updated from another device" for a few seconds above the
  canvas when a revision of another device changed what the note shows
  (`NoteEditor.remoteUpdates`). Signpost `note.remoteMerge` (detail: the
  outcome); `note.remoteMerge.apply` is its main-actor part (detail: pages
  compared, strokes visited). When the read named the changed pages, only
  those are compared and merged into their ledgers; the other pages, their
  ledgers, canvases and undo steps are left as they are.

## Performance timing (app)

Every phase above is an `os_signpost` interval (subsystem
`io.github.anthonytw.sempere`, category Points of Interest), in every build:
`vault.open`, `index.load`, `reconcile` (`.enumerate`, `.coordinate`,
`.download`, `.read`, `.validate`), `list.update`, `note.open`,
`note.download`, `note.read`, `note.reconstruct`, `note.cache`,
`note.convert`, `note.firstRender`, `cache.write`, `item.picture` (`hit` or
`drawn`), `pdf.open` (`fetched`, `adopted` or `cached`), `pdf.preview`
(`hit`, `drawn` or `missing`), and `change.notified` events. Comparing a first
open with a reopen: open a PDF note, close the app, launch it again, open the
note: `pdf.open … adopted` and `pdf.preview … hit` lines replace `fetched` and
`drawn`. `AttachmentPersistenceTests` prints `PERF-REPORT pdf-reopen` lines
in the CI `app` log. Debug builds also log each finished interval to the console
(`SemperePerf <phase> <ms> ms <detail>`) and to `Library/Logs/SemperePerf.log`
in the app container (the previous run's as `.1`):

```
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
    --domain-identifier io.github.anthonytw.sempere --source Library/Logs/SemperePerf.log --destination .
```

Details hold counts and 8-hex-digit note id prefixes only. `SEMPERE_PERF_LOG=0`
turns the debug log off; `SEMPERE_DEBUG_DRAWING_CACHE=0` runs without the
drawing cache, for comparisons.

## Recent vaults after a restart

Right after a device restarts, iCloud Drive (and other providers) can take a
while to come up: a recent vault's bookmark does not resolve yet, or it
resolves to a folder iCloud has not listed. Before this was handled, the launch
reopen took the failed resolve for a dead bookmark and dropped the entry, so
the vault vanished from the welcome list until it was chosen again.

Now (`RecentVaultAvailability.swift`, `VaultLibrary.states`):

* A recent vault is never dropped by a failed resolve or open; only Remove
  (swipe, or the row's context menu) takes it off the list.
* Each entry keeps the path where it was last reached (`RecentVault.path`), so
  the list knows it is in iCloud Drive or another provider without resolving.
* The library checks every entry off the main actor (`checkRecents`:
  bookmark resolution and a look for `vault.json` or its `.icloud` stand-in,
  under the bookmark's scope). A vault that may be in a cloud provider and is
  not reachable is **waiting** ("Waiting for iCloud…") for
  `RecentVaultCheck.patience` (3 minutes), then **missing** (the bookmark still
  resolves, the folder is gone and its parent is there) or **unreachable**
  (iCloud Drive off or signed out, or the vault went with its folder). A vault
  on this device has nothing to wait for and is reported at once.
* Checks repeat with a backoff (1, 2, 4, 8, 16, then every 30 s; once a minute
  for ten minutes when only gone vaults are left), and start over when the scene becomes active
  or the iCloud account changes (`NSUbiquityIdentityDidChange`).
* The launch reopen, File ▸ Reopen Last Vault and a tap on a waiting row do not
  show an error: the vault opens by itself as soon as a check finds it
  (`openWhenAvailable`, `takeReadyPendingOpen`), unless another vault was opened
  meanwhile.

The app has no iCloud container entitlement (free personal-team builds cannot
have one; vaults are folders the user picks), so there is no ubiquity container
to look up and no `NSMetadataQuery` over iCloud scopes: the bookmark and the
folder are what is checked. Tests fake the iCloud side with `FakeVaultCloud`
(`RecentVaultWaitTests`).

## Saved folder access (sandboxed Mac)

The app opens a vault folder through the system picker and remembers it as a
bookmark (`VaultBookmark`, recent vaults in `VaultLibrary`). Whether a
remembered folder is still usable after a relaunch is the platform's decision:

* **iPadOS:** a bookmark made from a picker URL carries its security scope;
  `startAccessingSecurityScopedResource()` on the resolved URL grants access.
  Verified on devices.
* **Mac Catalyst, not sandboxed:** the app can read what the user can; scope
  calls return false and nothing depends on them.
* **Mac Catalyst, sandboxed (Mac App Store, `Sempere.entitlements`):**
  `.withSecurityScope` is AppKit-only and is not in the Catalyst SDK, so
  bookmarks are made with plain options, as on iOS (`VaultBookmark.make`).
  Apple documents security-scoped bookmarks for sandboxed apps with the
  `com.apple.security.files.bookmarks.app-scope` entitlement (set) and
  `files.user-selected.read-write` (set); whether a plain bookmark of a
  picker URL brings the sandbox extension back after a relaunch under
  Catalyst **has not been verified**: it needs a signed sandboxed build on a
  Mac, which CI does not have.

What the code does so that either answer is safe:

* `AppModel.openVault` lists the folder before reading anything
  (`FolderAccess.check`). When the system refuses (`EPERM`/`EACCES`, Cocoa
  257/513, also as an underlying error) it throws `FolderAccess.Problem.noAccess`
  naming the vault folder, instead of a file error from inside `Vault.open`.
* `RootView.reopen` already turns any failure of a recent vault (other than
  waiting for iCloud, above) into a message and the folder picker, so a lost permission ends with the user choosing the
  folder again, and `remember` saves a fresh bookmark from that scope.
  At launch (`pickOnFailure: false`) only the message shows.
* A stale bookmark is re-saved while its scope is held (`VaultBookmark.resolve`).
* DEBUG builds log `SempereDebug folderAccess scoped=<0|1> listable=<0|1>` for
  every open (no names), to read the answer off a real sandboxed build: after
  choosing a folder and relaunching, `scoped=0 listable=0` means the plain
  bookmark does not survive, and the fix is a Catalyst-only
  `NSURL` bookmark call through an Objective-C shim, which this repository
  does not have.
* The vault's own files under `notes/` are written only through the open
  scope; nothing outside the picked folder is touched. The temporary PDFs of
  drag and drop (`docs/mac.md`) are in the app's container.

## Share and export (app)

The app exports notes through the system share sheet and Save to Files. It
renders with the CLI's renderers: `SempereRender.ShareExport` lays the files
out (the same bytes `sempere export` writes) and `TreeExporter` (in
`SempereRender`) writes the Markdown and HTML trees.

| Format | One note | Several notes |
| --- | --- | --- |
| PDF | `<stem>.pdf` | one per note, or one merged `Sempere-Notes.pdf` |
| PNG pages | `<stem>-p001.png`, ... (`-p001-2.png`, ... for the further images of a pageless page) | a folder per note |
| Text (Markdown) | `<stem>.md` leading with the recognized text; with the PDF (optional, off) or page PNGs, a folder with them and `README.md` | `Sempere Export/`, mirroring the notebook tree |
| Media | a folder `<stem>/` with the note's recordings, transcripts, clips, images and PDFs and `media.json` ("Media export" below) | a folder per note; notes without media are counted, not written |

`<stem>` is `ExportName.stem` (sanitized title and the first 8 characters of the
note id). Options: paper background (on), PNG resolution (72, 144, 216, 300
dpi), merged PDF, and for text the PDF (off) and page images. The text export
is disabled when no selected note has recognized handwriting, the media
export when none has a recording, video, image or PDF. HTML is the
CLI's only (`sempere export --format html`). A one-off share writes no export
manifest.

- **Selection.** "Select" in the note list ticks several notes; a keyboard
  command-click does too. The export commands act on the ticked notes, else the
  open note. `ExportCommand` is the one place that names the actions: the list
  toolbar and context menu, the note toolbar and the Catalyst menu bar
  (`ExportMenuCommands`, File menu) all build from it.
- **Off the main actor, with cancel.** `AppModel.exportNotes` reads each note
  (iCloud notes are downloaded first, reads are coordinated and re-check
  `CloudVault.requireLocal`, so a note missing a revision is reported as a
  failure, never exported stale; same rules as opening a note) and renders in a detached task, checking cancellation between
  notes. `ExportJob` drives it for the export sheet: progress over both phases,
  Cancel, failures listed per note while the others are exported (also in a
  merged PDF, which leaves out a note that cannot be rendered). One export at a
  time: an Export command while the sheet is up is ignored. Closing the
  vault cancels it (generation token). Nothing is written to the vault.
- **Scratch files.** Output is staged under `tmp/SempereExports/<uuid>` (file
  protection "complete" on iOS), deleted when the sheet closes and at every
  launch. A run owns its folder: a run that is canceled, fails or outlives
  its sheet deletes it when it ends (the note being rendered at that moment
  finishes, and no file is written once the run is canceled). Share and Save to Files copy from there.
- **Plaintext.** Exports strip nothing and encrypt nothing, exactly like the
  CLI's; the sheet says so. The share sheet holds the selected notes' states at
  once while rendering; "Export to Folder or Zip…" (below) streams one note at a time.

The app's Markdown/HTML share export never skips notes as up to date: it writes into a fresh
scratch folder and deletes the manifest afterwards (`ShareExport`), so there is nothing to compare
with; `TreeExporter.environment` stays unset there. Only the CLI re-runs into the same folder.

## Bulk export (app and CLI)

"Export to Folder or Zip…" exports many notes at once: the ticked notes of the list
(Export ▸ To Folder or Zip…), a notebook with its sub-notebooks (the
notebook's context menu), or the whole vault (All Notes' context menu, and
File ▸ Export to Folder or Zip… on a Mac, which takes the ticked notes, else the
sidebar's notebook, else the vault). iPad, iPhone and Mac share the sheet
(`BulkExportSheet`).

- **Formats.** PDF (one file per note), PDF + attachments (recordings with
  their transcripts and video clips embedded and listed on a last page, as the
  share sheet's "PDF + attachments"), PNG pages (a folder of `p001.png`, ...
  per note), Media (a folder per note, "Media export" below; notes whose
  summary names no audio, video, image or PDF blob are not planned, so they
  are never read). SVG is the CLI's only, as in the single-note export.
- **Layout.** "Folders like your notebooks" (on by default) mirrors the
  notebook tree (`TreeExporter.folders`: sanitized segments, names that differ
  only by case share one spelling); a notebook export starts at that notebook
  (`School/Math` gives `Math/…`). Off: every note at the top.
- **Names.** `ExportName.stem` (`<title>-<8 hex of the id>`): path separators,
  `\ : * ? " < > |`, controls and newlines become `-`, length is capped, an empty
  title is `untitled`, reserved folder names (`CON`, `NUL`, ...) get `_`. Two
  notes whose names would still clash in one folder (equal ignoring case and
  Unicode normalization, or equal to a sub-folder's name) take the full id,
  then `-2`, `-3`, ...; the note with the smaller id keeps the short name, so
  a re-run names every note the same way (`BulkExportPlan.jobs`).
- **Destination.** A folder the user picks (the default on a Mac; on iPadOS
  any Files location): files are written in place, the picked folder's
  security scope held for the run. A folder inside the vault is refused. Or a
  zip archive (the default on iPad and iPhone), staged under
  `tmp/SempereBulkExports/<uuid>` (file protection "complete"), then Share…
  or Save to Files…; deleted when the sheet closes and at launch.
- **One note at a time, bounded memory.** `AppModel.runBulkExport` loops over
  the jobs: download (iCloud), read (coordinated, `requireLocal` before and
  after, as for the share export), fetch embedded media for PDF + attachments
  (every file it writes for Media),
  render and write in a detached task, then let go. Only one note's state is
  held; PDFs stream (clips never in memory) to `<name>.pdf.partial` and are
  renamed when complete; zip entries are streamed from those files
  (`ZipWriter`: stored, CRC first, zip64 past 4 GiB or 65 535 entries) and the
  staged files deleted. A 1.4 GB vault takes the memory of its largest note.
- **Read ahead, bounded by bytes.** While a note renders, the next ones (at most two)
  are downloaded and read (`LoadAhead`, SempereRender): one read at a time and in job
  order, so iCloud downloads still happen in the order the jobs run, and wall time
  approaches the longer of the read and render phases instead of their sum. The
  estimated memory of the note being rendered plus those read ahead stays under 256 MiB
  (`ByteBudget`; a note's estimate is 8 × its revision files on disk, 64 MiB when they
  cannot be measured). A note that does not fit is read on its own, when its turn comes,
  and nothing after it is read before it has been reserved (the reads after a note that did not fit, or that is up to date and skipped, wait for it, then go on). Reading ahead never touches the
  `BulkExportSession`, except `wouldSkip` (a read-only `skip`, so a note that is up to
  date is not read): `skip`, `fail` and `export` still happen in job order from the one
  loop, so the outcomes, the skipped and failed counts and Stop behave as one note at a
  time. Stop and closing the vault cancel the reads in flight and wait for them.
- **Progress, Stop, failures.** Progress counts notes (and skipped and failed
  ones). Stop ends after the note being written: a folder keeps what was
  written, a zip is deleted. A note that cannot be downloaded, read or
  rendered is listed at the end ("Not exported", title, id prefix, reason) and
  the batch goes on; nothing is half written for it. Closing the vault stops
  the run (generation token). Nothing is written to the vault.
- **Resumable-ish.** The folder gets a hidden manifest,
  `.sempere-export-bulk.json`: per file, the note id, the note's version (a
  fingerprint of its revision file names, `BulkExportPlan.version`), the
  options (`BulkExportOptions.fingerprint`) and the size written. Exporting
  again into the same folder skips a note when every file it wrote is still
  there with the same name and size, for the same note version and options,
  before anything is downloaded or read; the sheet and the CLI say how many
  were skipped. The manifest is saved every 10 notes and at the end (also
  after Stop), so an interrupted run redoes at most ten notes. It is untrusted
  when read back: a path that would leave the folder is ignored, and it can
  only make a run skip, never delete. A zip is never resumed.
- **Shared core.** `BulkExportPlan` (selection → jobs), `BulkExportSession`
  (skip, render, write, manifest, zip) and `ZipWriter` live in
  `SempereRender`; `sempere export --all --format pdf|png` runs the same
  session (docs/cli.md "Bulk export"), and the sheet shows the equivalent
  command for a notebook or the vault.

## The attachment list page (app and CLI)

"PDF + attachments" (the share sheet's and "Export to Folder or Zip…"'s, the CLI's
`--attachments`, `--recordings attach`, `--videos attach`) ends with a list of
what the PDF carries: one row per recording, its transcript (when embedded) and
video clip, with the kind, the title, the pages of the PDF it appears on (a
recording's cards, a clip; "–" for none), the duration and the size. The rows
follow the notes (a merged PDF heads each note's rows with its title), the
recordings in their order, then the clips in page order. US Letter, as many
pages as the rows need (about 35 rows a page; a title too long for its column
is cut at the end of its first line).

- **Links.** Each embedded file gets a FileAttachment annotation (the viewer's
  paperclip in the left margin) naming the same file specification as the
  document's `/EmbeddedFiles`: opening it opens or saves the file, also in
  viewers that have no panel for document attachments. The
  Page column links to the first page it appears on. `pdfdetach -list` counts
  each file twice (the name tree and the annotation); the file is stored once.
- **Not embedded.** A recording or clip left out (missing, not downloaded,
  over the size limit) is listed with "(not embedded)" and no file link.
  `sempere export --recordings list` lists them all without embedding anything.
- **Text.** Laid out by the export's shaper (CoreText in the app, the bundled
  Noto in the CLI), so it is the same page from both; without a shaper the
  page is left out with a warning. A note without recordings or clips gets no
  page. Shared code: `AttachmentList` (SempereRender), drawn by `PDFWriter`.

## Media export (app and CLI)

"Media" (the share sheet, "Export to Folder or Zip…", `sempere export --format media`)
writes a note's attachments as files: one folder per note, named like its
other exports (`ExportName.stem`), holding

- each recording, byte for byte as stored, and its transcript as a `.txt` of
  time-stamped lines (`Transcript.plainText`) next to it;
- each video clip, streamed from the vault, location metadata removed in place
  unless kept (`--keep-image-metadata`), as "PDF + attachments" does;
- each image, JPEG and PNG with their metadata removed unless kept (other
  formats, and JPEG or PNG over 64 MiB, as stored, with a warning);
- each PDF (the document behind `pdfPage` items), as stored;
- `media.json`: `{"format": "sempere-media/1", "note", "title", "files": [{"file",
  "kind" (recording, video, image, pdf), "title", "pages" (1-based note pages
  it appears on), "duration", "started" (RFC 3339), "transcript" (the .txt),
  "type", "size"}]}`.

Each blob is written once however often it is placed. Names are
`<title>-<Kind>-<n>[-<recording title>].<ext>` (`Physics-Week-3-Recording-1-Lecture.m4a`,
`…-Image-2.jpg`), every part through `ExportName.component`, the title and the
recording title capped at 60 bytes, unique ignoring case; the extension comes
from the media type (`bin` when unknown). Every file is decrypted and verified
on its way out (`BlobSource.stream`, never whole in memory) into a temporary
file next to its name and moved into place. A blob that is missing or not
downloaded is left out with a warning; one that fails verification while it is
written fails that note (its files are removed) and the export goes on. A note
without media writes nothing (the CLI warns, the app counts it). The bulk export
records the files in its manifest, so a re-run skips unchanged notes and a
changed note's earlier files are removed first. Shared code: `MediaExport`
(SempereRender), used by `ShareExport`, `BulkExportSession` and the CLI.

## Vaults are folders (app)

The app exports the UTType `io.github.anthonytw.sempere.vault` (extension
`sempere`), conforming to `public.folder` only (`Apps/Sempere/SempereInfo.plist`,
merged into the generated Info.plist), so opening a vault from Files launches
Sempere. It is **not** a package (`com.apple.package`): iCloud Drive syncs a
package as one item, so a note written into it on one device while another
device also wrote (a large import on the Mac, a new note on the iPad) made a
conflict of the whole vault, and the version the user did not pick in the
system's "choose a version" prompt took that note with it (TestFlight 1.0.0,
2026-10). As a plain folder each file syncs on its own, write-once files never
conflict, and the app resolves the few mutable files itself ("Conflicting
versions" below). Files and Finder show a vault as a folder.

The picker accepts that type and plain folders. `VaultLocator.resolve` turns
what was picked into the vault folder: a folder holding exactly one
`.sempere` resolves to it (several: an error naming them). A file or folder
inside a vault (`vault.json`, `notes/…`) is an error naming the vault: the
access the picker grants covers the picked item and what is below it, never
its parents, so the vault could not be read from it.
New vaults are always created as `<name>.sempere`. Security scope is held on
the URL the user picked. The CLI and the on-disk layout are unaffected.

A vault created by a build that still declared the package type may be held
by iCloud Drive as a package until it is re-created; `sempere vault
merge-copy` merges any copy of it (the other device's, or a version restored
from iCloud's version history) into a new vault without losing a file.

## Conflicting versions (app)

iCloud Drive keeps a *conflict version* of a file two devices replaced at
once (`NSFileVersion.unresolvedConflictVersionsOfItem`). Before every full pass
of the sync loop (`AppModel.resolveCloudConflicts`, `CloudConflicts.swift`) the
app looks for them on the vault folder itself (a vault that conflicted while it
was a package), `vault.json`, `rewrap-journal.json`, `settings.age`, the
published summaries and `keys/`, merges them by the rules of `format.md` §1.3,
marks them resolved and removes them, so the system never has to ask the user
to pick a version:

- the vault folder: `Vault.mergeCopy` (the library code behind `sempere vault
  merge-copy`): every write-once file the kept version lacks is checked and
  copied in, so a note written on either device is listed (the notes it brought
  back are looked at by the same pass); its `settings.age` waits for the key;
- `settings.age`: merged per key once the vault is unlocked (while locked the
  conflict stays until the unlock);
- `vault.json` and the journal: the current version stays when the other is the
  same or differs only in the label; otherwise (both devices changed the keys)
  it is left unresolved and the list's bar says so;
- published summaries and key files: the current version stays.

Revisions and blobs are write-once under unique names and never conflict.
Tests fake versions with `FakeCloud.addConflict` (`CloudConflictTests`).

## Atomic writes

Every file the library writes (revisions, `vault.json`, identity files, the
rewrap journal) goes through one helper:

1. write the bytes to `.sempere-tmp-<uuid>` **in the destination directory**
   (same filesystem, so the rename cannot turn into a copy);
2. `fsync` it;
3. `rename(2)` it onto the final name;
4. `fsync` the directory, so the rename itself survives a crash.

A reader or a sync client sees either no file (or the previous version) or
the complete new one, never a partial file. Temp names start with a dot and
lack the `.age` suffix, so every listing ignores them. Deletions (compaction,
the journal) also fsync their directory. Filesystems that cannot fsync a
directory (`EINVAL`, `ENOTSUP`) are accepted (`verify` reports a
leftover as `unknownFile`; nothing deletes it automatically).

**Blobs** (`notes/<id>/att/`, `format.md` §8.1.4) are streamed: the age
file is written chunk by chunk to `.sempere-tmp-<uuid>` in the note's `att/`
(mode 0600) and `fsync`ed, then put in place with `link(2)` onto the final
name, which fails rather than replace an existing file, then the temporary
name is unlinked and the directory `fsync`ed. On file systems without hard
links (FAT, some network shares) it falls back to the existence check and
`rename(2)` above. The only blob that is ever replaced is one whose first
chunk does not decrypt to a valid header for its name (format.md §8.1.4
step 2), or, during a recipient change, a blob rewritten in place or a
damaged file under its new name (§8.1.5). Writers write the blob before the
revision that references it, so a crash leaves an unreferenced blob, never
a dangling reference. `withBlobFile` and `blobs extract --out` decrypt to a
private file that appears (or is handed out) only once the whole content
verified.

Revisions are write-once: `write` refuses an existing name and a reused
`(device, seq)` before renaming. The existence check and the rename are not
one atomic step, but two writers can only race on one name if they share a
device id and sequence number, which the format already rules out.

`nextSeq` takes the largest `seq` seen in file names **and** in any readable
snapshot's `included`, so a device whose old revisions were compacted away
does not reissue a `seq` that a snapshot already claims to cover (which
would make readers drop the new delta).

## Backups

`Backup` (`Sources/Sempere/Backup.swift`) copies a vault's format files
(`vault.json`, `rewrap-journal.json`, `settings.age`, `keys/*.key.age`, `notebooks/*.notebook.age`,
`notes/<id>/<revision>`, `notes/<id>/att/<blob>`;
nothing else) with the same atomic-write helper, then reads each copy back
and compares SHA-256. The backup folder is a vault plus `backup.json`
(`format: sempere-backup/1`, `vaultId`, `created`, `updated`, `completed`,
and `files`: path → `sha256`, `size`)
and `versions/<UTC time>/` (previous copies of files a run replaced or, for
the journal, removed). Revisions are copied first and `vault.json` last, so a
run cut short never leaves a manifest newer than its notes; `restore` writes
`vault.json` last for the same reason, behind a `.sempere-restore.json`
marker that lets the same command resume. `backup.json` is saved every 100
files (every twentieth of the index once it holds more than 2 000 entries) and at the end; a file on disk that it does not list is hashed against
the source before it is trusted. `--prune` uses `CompactionPlanner` with
retention 0 over snapshots present in both the source and the backup (a
pruned snapshot's own coverage is read from the backup's copy), as WebDAV sync
does for deletions. The tar writer is POSIX ustar (names up to 255 bytes via
the prefix field); the archive is verified with a small reader before it is
renamed into place.

`updated` is written by every run (also one with file errors, and the
periodic saves of one cut short); `completed`, optional, only at the end of a
run without a file error, so it is what an overdue check counts from. `Backup.status` reads
`backup.json` alone (last run, last complete run, notes, files, bytes,
sizes summed with saturation since the index may be hostile);
`Backup.preview` lists a backup or vault folder without a key (notes,
revisions, attachments, bytes, newest revision from the file names' clocks);
`Backup.checkRestoreTarget` refuses a target before anything is written,
including one that is, holds or lies inside a `protecting` folder (the open
vault). The CLI's `backup status` and `restore --dry-run` and the app use them.

### Backups in the app

Settings ▸ Backups (`AppModel+Backup.swift`, `BackupSettings.swift`,
`BackupViews.swift`) runs the CLI's core; `docs/cli.md` "The app's Backups"
maps each control to its command.

- **Folder.** The user picks a folder (another drive, another cloud
  provider's folder in Files). The backup goes into the folder itself when it
  is empty or already this vault's backup, else into "<vault> Backup" inside
  it (the next free "<vault> Backup N" when that name holds something else;
  `BackupLocation.subfolder`). A vault, another vault's backup, the open vault
  or a folder inside it is refused. The app keeps a bookmark of the picked
  folder (`VaultBookmark`, plain options as for vaults, see "Saved folder
  access") plus the subfolder name, per vault and per device
  (`BackupRecord` in `UserDefaults` under `Sempere.backup.<vault id>`); access
  granted to the picked folder covers the subfolder. Picking an existing
  backup takes its last backup from `backup.json`'s `completed` (a run with
  file errors or cut short is none). A bookmark that no longer
  resolves, or a folder that is gone, is reported by name ("choose it again").
- **Back Up Now** is `Backup.run` off the main actor, with the picked folder's
  security scope held for the run. An iCloud Drive vault is made local first,
  every note (`downloadEverything`) and every attachment blob: a placeholder
  is not a file `Backup.run` sees, so it would be missing from the backup.
  The run's `afterEachFile` counts files for the progress line and stops the
  run when the user taps Stop or the vault closes (the backup holds only
  complete files; the next run finishes it). The run counts as the last
  backup only without file errors. After a Verify Backup found problems, the
  next run compares every file by hash (`--checksum`), so damaged copies are
  replaced, not skipped for having the right size.
- **Verify Backup** is `Backup.verify` with the unlocked key (every revision
  decrypted and checked), or hashes only when the vault is locked; the
  problems are listed (`BackupVerifyReport.problemLines`; at most
  `BackupText.problemLimit` in a box that scrolls, then "…and N more."). A folder
  that cannot take the backup and a failed run or check are alerts.
- **Reminder.** "Remind me after N days without a backup" schedules one local
  notification per vault (`UNUserNotificationCenter`, identifier
  `Sempere.backupReminder.<vault id>`), due N days after the last backup, or
  after the reminder was switched on when there is none, but never sooner than
  an hour from now. It is rescheduled after every backup, every change of the
  setting and every unlock; Settings shows an overdue backup in red even when
  notifications are not allowed. The text names the vault, never a note. The
  due rule is `BackupSchedule` (core), shared with `sempere backup status
  --max-age`, which counts from `backup.json`'s `completed` instead of this
  device's record; a last backup dated more than a day ahead of the clock
  counts as overdue.
- **Restore from Backup** (Settings, and the welcome screen when no vault is
  open): pick a backup folder, a folder holding one, or any vault folder
  (`BackupLocation.restoreSource`); the sheet shows `Backup.preview` (notes,
  versions, attachments, size, newest change, when it was backed up) before
  anything is written. The restore goes into a new "<name>.sempere" on this
  device or in a chosen folder through `Backup.restore(protecting: [open
  vault])`, coordinated in iCloud Drive; a backup whose `vault.json` does not
  open (one listing a classic key, say) is refused as in the CLI. The new vault is added to the recents and can be
  opened from the sheet; it has the backed-up vault's id and opens with the
  same key. The open vault is never written.
- A backup folder in iCloud Drive is downloaded before a restore; a backup
  *into* iCloud Drive is written with plain file writes, which iCloud uploads,
  but an evicted file of an earlier run there reads as missing to Verify
  Backup. Prefer a folder that stays local (an external drive) or another
  provider.

## Listing errors

A directory that does not exist lists as empty (sync tools drop empty
directories). Any other listing failure throws `VaultError.io`
(`noteIDs`, `revisionNames`, `identityFiles`, `nextSeq`, the rewrap) or, in
`verify()`, becomes an `unlistable` entry that makes the report unhealthy.
"Could not read" never looks like "nothing there".

`nextSeq(noteId:device:)` throws when a snapshot of the note cannot be read,
since its coverage is unknown. Callers that already hold all revisions use
`Vault.nextSeq(from:device:)`, which reads nothing (`snapshot()` does).

## Recipient changes and resumability (§3.3)

The only in-place rewrite. The procedure is the recommended one of
`format.md` §3.3.1; this section explains the reasoning. Order of operations:

1. Write `rewrap-journal.json` at the vault root; the atomic write fsyncs
   the root directory, so the journal is durable before `vault.json` changes. When the secret rotates
   (recipient removed) it holds the **outgoing** vault secret, age-encrypted
   to the new recipient set.
2. Write `vault.json` with the new recipients and `vaultSecret` (fresh on
   removal), `recipientsTag` for them and, on removal, `secretLink` signed by the
   outgoing secret's keys (format.md §2.1), in the same atomic write; then save this
   device's trust record. Before step 1 the current list must check
   (`requireWritable`): a planted list, or a planted journal next to one, is
   never resumed or rewrapped to.
3. For every revision file: decrypt with our identities, then
   - **skip** it if its header has exactly one stanza of the matching type
     (`mlkem768x25519`) per current recipient (and no other stanzas)
     and its tag verifies under the current secret (already done);
   - otherwise re-encrypt the same plaintext to the new set (on removal,
     first re-tag the unchanged gzip bytes with the new secret, after
     verifying the old tag with the outgoing secret) and replace the file
     atomically.
4. Remove `rewrapPending` from `vault.json` (step 2 wrote it: an HMAC under the
   new secret over the journal's bytes), then delete the journal, but only if
   every file completed. The binding goes first, so a journal left by a crash
   between the two is refused, never accepted again; the device then marks its
   trust record `rewrapFinished`. Any failure
   (unreadable file, tag that verifies under neither secret, ...) keeps the
   journal and with it the outgoing secret: deleting it would turn a
   transient I/O error into a permanent tag failure. `pendingRewrap` stays
   true, the report lists the failures, `resumeRewrap()` retries them, and
   no new recipient change starts until it completes
   (`VaultError.rewrapIncomplete`).

If the process dies anywhere, the journal is still there. `Vault.open`
notices it (`pendingRewrap`) and, when it accepts it (format.md §3.3.1: linked by
`secretLink`, bound by `vault.json`'s `rewrapPending`, and not a change this
device saw finish), keeps the outgoing secret so files not yet
rewrapped still verify (if the journal cannot be read, `open` records why in
`journalProblem`; `verify()` reports it and such files fail as
`tagMismatchJournalUnreadable` instead of a plain tag mismatch), and `resumeRewrap()` (or simply repeating the same
`addRecipient` / `removeRecipient` / `replaceRecipient` call) finishes step 3 and 4. Files that
are already current are skipped, so a run can be repeated any number of
times.

**Blobs in a recipient change** (`Sources/Sempere/BlobRewrap.swift`). After
a note's revisions, each blob in its `att/` is checked from its first chunk
only (stanza counts, and the name against the hash in its header): complete
blobs are skipped. Others are rewritten by the method the journal records
(`rekeyBlobs`, chosen by `RewrapPolicy`): header-only (`AgeFile.rewrapHeader`)
or full re-encryption (`AgeFile.reencrypt`), streaming, with the whole
plaintext checked on the way (framing, zero padding, hash), to a temporary
file. A blob named under the current secret (an addition) replaces itself; one
named under `previousVaultSecret` (a removal) goes to its new name and then the
old name is deleted, and a run that finds a complete copy already under the new
name (a crash between the two) only deletes the old one. A blob whose name
verifies under neither secret, or whose content fails a check, is left as it is
and reported, which keeps the journal. While the journal exists, lookups try
the current name, then the previous one.

Why a stanza count and not "the header lists all recipients":
`mlkem768x25519` stanzas carry only an encapsulation, not
the recipient, so a header cannot be matched against public keys. Within one
change the counts differ (n−1 vs n on add, n+1 vs n on remove), and on
removal or replacement the tag under the new secret also tells old from new
(a replacement changes no count, so the rotated secret is what marks a file
done).

`replaceRecipient` (a key rotation) is a removal and an addition in one pass. Its pending files are encrypted only to
the outgoing key, so unlike add and remove it cannot be finished by a device
that holds only a key of the new set: resuming needs the old identity too.
The CLI says so, and the old key must be kept until no rewrap is pending. The journal blocks any other recipient change until
it is resolved, so counts from two changes never mix.

A file that verifies under neither secret (tampered or planted) is never
re-tagged: it is left untouched and listed in the report's `failures`, so a
rewrap cannot launder a forged file into a valid one. `verify()` also flags
files whose stanza count differs from the manifest as `staleRecipients`.

## Reading and verification

`readRevision` reports one typed error per stage: `undecryptable` (age),
`tagMismatch`, `corruptBody` (magic, version, gzip), `undecodable` (JSON, or
content naming another note or file name). `reconstruct` and `snapshot`
refuse to proceed past an unreadable revision; `loadNote` returns what is
readable plus the failures. `compact` deletes only names returned by
`CompactionPlanner` over readable revisions, so an unreadable file is never
deleted and never counts as coverage. `verify()` never throws: it re-checks
`vault.json` (format, recipients, the secret's stanza count) and gives every
entry a status.

## Sync engine and transports (`Sources/SempereSync`)

The two-way sync described under "WebDAV sync" below is one engine, `SyncEngine` in the
`SempereSync` target (Foundation and swift-crypto only, no network code, Linux-tested). Every rule
lives there: what is copied, checked before it is placed (format.md §9.1), quarantined, deleted
and recorded (`SyncState`), the run bounds (`SyncLimits`), partial copies (`PartialRun`,
`FetchScope`, `PartialCopyState`), push-only mirrors and the app's local copies (`LocalCopy`).
It reaches the other side only through the `SyncRemote` protocol (`SyncRemote.swift`), whose
operations are the ones the engine makes, with transport-neutral names:

| `SyncRemote` | What it does | WebDAV (`WebDAVSyncRemote`) |
| --- | --- | --- |
| `list`, `listTree`, `stat` | children of a collection, everything below one at once (or `.refused`), one file's metadata; nil when absent | PROPFIND `Depth: 1`, `Depth: infinity`, `Depth: 0` |
| `read(_:maxBytes:)` | a bounded file and its version token (`etag`) | GET |
| `download(_:to:resumeFrom:ifETag:…)` | a file streamed to disk in pieces, resumed when its strong version token still matches; one that cannot resume starts over | GET with `Range` / `If-Range`; a 416 starts over |
| `write(_:_:condition:)` | data or a file, `PutCondition` `.create` / `.replace(etag:)` / `.unconditional`; false when the precondition failed | PUT with `If-None-Match: *` / `If-Match` |
| `moveNoOverwrite`, `makeCollection`, `createBase`, `delete(_:ifETag:)` | rename without replacing, make a collection (or report its missing parent), make the base, delete (only that version) | MOVE `Overwrite: F`, MKCOL, MKCOL of each ancestor, DELETE with `If-Match` |
| `interrupt`, `location`, `missingCollectionError` | the run's bound and cancellation reach a request in flight; where the remote is, for messages; the transport's own "not there" error | `WebDAVClient.interrupt`, the URL, a PROPFIND 404 |
| `capabilities`, `RemoteEntry.availability`, `requestDownload`, `conflictVersions`, `resolveConflicts`, `changes` | what the remote promises (`RemoteCapabilities`: strong stamps, ranged reads, deep listing, folder stamps that follow a child write, atomic create, maximum object size), and hooks for stores that evict files, fork conflict versions or announce changes; defaults: available, nothing to do, no versions, no hints | strong stamps, ranged reads, deep listing and folder stamps (each still checked per server), no atomic create (blobs go to a temporary name, then MOVE); the hook defaults |

Engine failures are `SyncError` (`vaultMismatch`, `limitExceeded`, `cancelled`, ...); a transport's
own failures are its own error type and pass through unchanged (`WebDAVError`). A transport marks
the ones a later run may not see (no network, a cut connection) as `TransientRemoteError`, so the
engine keeps a partial download for the next run.

**The in-memory transport.** `MemoryRemote` (`MemoryRemote.swift`, in `SempereSync`, Foundation only)
keeps a vault layout in a `MemoryStore` shared by every remote made on it (one "server" for several
devices) and keeps every promise above: counter version tokens, create-only and conditional
writes, moves that never overwrite, ranged and resumed downloads, deep listings, folder tokens that
change with anything below them (`MemoryStore.Behavior` sets atomic writes and a size limit, and
`capabilities` reports them). `MemoryFaults` breaks those promises from a seed, per operation and
path (so concurrent transfers replay): requests dropped, refused, applied with the answer lost or
cut midway, latency (interruptible), and a hostile server's wrong bytes, listings that drop or
invent entries or misreport sizes, and version tokens that change underneath. The store can also
act like a provider that evicts files (`evict`, or every file as it is written:
`Behavior.evictOnWrite`; `requestDownload` after `arrivalDelay` operations; folders listed before
their children, `setArriving`, listed as not downloaded until asked for), which the engine's arrival
rules (below) handle.
It serves the transport conformance suite, the engine's scenarios over every transport and the
N-device stress run (docs/ci.md "Transports", "Sync stress"); nothing in the app or the CLI uses it.

**The folder transport.** `FolderRemote` (`FolderRemote.swift`, in `SempereSync`, Foundation and POSIX
only, Linux-tested) is a `SyncRemote` over a directory: a vault folder in iCloud Drive or another
provider, on a USB drive, a network share or anywhere else (`sempere sync folder`; the app's folder
targets later, design §8.1). What it promises:

| | How |
| --- | --- |
| version tokens | `"<device>-<inode>-<size>-<mtime ns>-<ctime ns>"` from `lstat(2)`, plus 16 hex digits of the SHA-256 of a file at the base of at most 64 KiB (`vault.json`, `settings.age`, the journal: the files rewritten in place). Never the modification time alone: a replace through a new file changes the inode and the change time within one tick of a coarse clock (FAT: 2 s), and the digest catches a same-size rewrite in place where neither moves. Strong |
| create only | a hidden temporary file in the same folder (`.sempere-tmp-<uuid>`), flushed, then `link(2)` (fails if the name exists); where the file system has no hard links (FAT, some shares), a check and `rename(2)` under the lock |
| conditional replace and delete | the token compared and the file renamed (or unlinked) under the lock: an advisory `flock(2)` on `.sempere-lock` at the base (hidden from listings) in a plain folder, the coordinated write itself in a provider's |
| reads | bounded (the size first, then never more than the bound), opened without following a link (`O_NOFOLLOW` at each folder); downloads resume at an offset when the token still matches |
| a hostile folder (format.md §9) | symbolic links never followed nor listed (every other operation checks each component first), FIFOs, sockets and devices not listed, names that are not UTF-8 never listed, unusable path components refused, listings bounded (`Limits.maxEntries`) |
| errors | `FolderRemoteError`; I/O failures a later run may not see (`EIO`, `ENOTCONN`, `ESTALE`, `ETIMEDOUT`, a full disk, ...) and the lock staying busy are transient; missing files, bounds, links and bad names are not |

What a provider adds comes from a `FolderProvider` (`FolderProvider.swift`): `PlainFolder` (Linux's
default: nothing to add), `UbiquitousFolderHooks` (Apple platforms' default, `#if canImport(Darwin)`,
below) and `EvictingFolderProvider` (a provider simulated on any file system for tests:
dataless files, `.<name>.icloud` stand-ins, folders listed before their files, delayed delivery,
download errors, conflict versions, change hints; the design's `EvictingFolderRemote` is a
`FolderRemote` over it).

### Folder targets in providers

A vault folder that iCloud Drive or another provider holds keeps every hazard the app's in-place
iCloud code handled (design §3.3); the folder transport and the engine handle them instead, so they
apply wherever a folder target is, and to the CLI:

- **Classification** (`FolderLocation`, moved from the app's `StorageLocation`): iCloud Drive, a
  Mac's `~/Library/CloudStorage/<Provider>-…`, iPadOS's `File Provider Storage` and shared app-group
  containers are a provider's (`managesFiles`), and so is any folder whose items report
  `isUbiquitousItem`. Every read and write there is coordinated (`NSFileCoordinator`, reads with
  `.withoutChanges`); a plain folder is not.
- **Evicted files.** In a ubiquitous folder, a `.<name>.icloud` stand-in is listed as `<name>`, and a
  dataless file (`SF_DATALESS`, or a "not downloaded" downloading status) under its own name; both
  are listed with `availability` `.remoteOnly` (`.downloading` once asked for, `.failed` with the
  provider's error). Reading one throws `FolderRemoteError.unavailable` (transient, `isUnavailable`)
  instead of blocking on a download.
- **Folders listed before their files.** A folder (other than the base) that lists no visible file
  yet is `.downloading`; the base itself not downloaded makes every listing fail (transient), so a
  run stops before it judges anything.
- **Conflict versions** (`NSFileVersion`): `conflictVersions`, `readVersion`, `resolveConflicts`.
- **Change hints**: `changes()` is an `NSFilePresenter` on the base (any coordinated writer: iCloud's
  daemon, the app, the CLI), as paths below it; elsewhere nil (poll).

The engine's rules for them (`Arrivals.swift`, `ConflictVersions.swift`), for any transport that
lists availability:

- **A listed file exists.** An evicted file is never taken as dropped, missing or extraneous: it is
  in the listing, so nothing is uploaded over it and no deletion is judged from its absence. Files
  the run would download that the provider has not downloaded are asked for (`requestDownload`, in
  windows of 64) as soon as the listings are in; each read waits for its file, all of them together
  at most `SyncOptions.arrivalWait` (10 s; the CLI's `--wait`, 30 s). What has not arrived is
  reported in `SyncReport.arriving` and left for a later run (its note records no folder stamp, so
  the next run lists it again); a dry run or a mirror asks for nothing. One still arriving
  `arrivalStall` (15 min) after this device first asked for it is reported in `errors` instead (the
  provider may be offline or full): never deleted, never given up on.
- **Folders listed before their files** (`notes/`, a note folder, its `att/`, `notebooks/`) are
  arriving for `unlistedTimeout` (120 s, iCloud's `cloudUnlistedTimeout`) from when this device first
  found them so: the note is left out of the run with its records kept, nothing in it judged. After
  that its listing is taken as it is: an emptied folder still deletes nothing (an emptied remote
  folder never explains a deletion) and its files are put back. So "arriving" never waits for ever.
  An `att/`-only folder (an import in progress elsewhere: blobs before their revision) is not a note
  until a revision appears.
- **The remote's `vault.json`** is waited for before anything else; still away after the wait, the
  run stops (`SyncError.notDownloaded`) rather than sync without knowing it is the same vault.
- When each one was first seen is kept in the sync state (`SyncState.arriving`), so the bounds hold
  across runs and processes.
- **Conflict versions** of the root's mutable files are settled before they are synced (format.md
  §1.3, §13.3; the app's `CloudConflicts` rules): a `vault.json` version that is the current file or
  differs only in its label is dropped, any other `vault.json` or journal version is kept as a local
  conflict copy and reported (exit 3); `settings.age` versions that verify are merged per key into
  the local copy (locked: left until an unlocked run), which the settings sync then merges with the
  remote's; the web viewer's summaries and index keep the current version. Then the versions are
  removed, so no version picker ever reaches the user. Mirrors and dry runs leave them alone.

**Adding a transport.** Conform a type to `SyncRemote` in its own target; one that talks to a
network goes beside `SempereWebDAV` and needs the network allowances (`scripts/check-portability.sh`,
the `NETWORK_ALLOWED` list in `scripts/release-check.sh`, the privacy policy), and `SempereSync`
stays network-free. Map paths (component lists below the remote's base, built from validated vault
names; refuse a component that is empty, `.`, `..` or holds a `/`, as `WebDAVClient` does) and
version tokens (they change whenever the bytes do; a strong one, not `W/"…"`, backs conditions and
resumes), bound what is read, and keep the hooks' defaults unless the store needs them. Then give it
a fixture in the conformance suite and the engine's scenarios (docs/ci.md "Transports"). Possible
later ones are first-class S3-compatible or Dropbox adapters (docs/design/device-first-sync.md §3.4).

## WebDAV sync (`Sources/SempereWebDAV`)

The one target with network code: the WebDAV client and transport, and `WebDAVSyncRemote`, the
engine's WebDAV adapter (the engine itself is in `SempereSync`, above). It talks to a plain WebDAV collection that
holds a copy of the vault folder (same layout, `vault.json` at the collection
root) using PROPFIND (Depth 1; one `Depth: infinity` listing of `notes/` where the server is seen to answer it in full, "One listing for every note folder" below), GET (with `Range` for blobs), PUT, MKCOL, MOVE and DELETE, so any server
works (Nextcloud, Apache `mod_dav`, nginx dav, rclone serve webdav,
wsgidav). Everything is behind `WebDAVTransport`; `URLSessionTransport` is
the real one (it never follows redirects, so credentials cannot be forwarded
and methods cannot be rewritten) and tests use an in-memory server.

**Security.** Basic auth, `https` only; `http` is accepted for `localhost`,
`127.0.0.1` and `[::1]`. Credentials in the URL are refused. Everything on the
server is already age-encrypted, except `vault.json` (public by design).
A remote `vault.json` with another `vaultId` aborts the run before any
change.

**What is synced.** `vault.json`, `rewrap-journal.json`, `settings.age` (shared
settings, merged per key: below), the notebook records `notebooks/<uuid>.notebook.age`
(format.md §14: write-once, so each side gets the other's; uploads only create, nothing is
deleted, and an unlocked run places a downloaded record only once it opens),
`notes/<uuid>/<name>.age` and each note's attachment blobs
`notes/<uuid>/att/<64 hex>.<kind>.age` (below). Remote entries that are not a lowercase-UUID note
directory, a canonical revision file name (format.md §5), an `att`
collection or a canonical blob name (format.md §8.1.2) are ignored and
listed, never downloaded, so a hostile name cannot escape the vault. The
capture inbox `inbox/<captureId>.<kind>.age` and the per-device published
summaries `summaries/<device>.sealed` are synced too (below). `keys/`
and unknown files are not synced. A downloaded revision must start with the
age header or it is rejected, and before it is placed it is checked as
format.md §9.1 says (tag, note and name with the vault unlocked; age
structure when locked); a file that fails is quarantined next to the sync
state (`<state>.quarantine/`; a later copy of the same path with other bytes
beside it as `<name>.copy-<16 hex digits of its SHA-256>`, never over one, at
most 16 distinct copies of a path), reported, and not fetched again while it and
the local `vault.json` are unchanged (`--retry-quarantined`). A first pull
with `--identity` checks under the `vault.json` it pulls. Remote names are reported with control
characters escaped, so a hostile name cannot drive the terminal. Response
bodies are read incrementally and the request is canceled past a limit
(`maxFileBytes`, 256 MiB, for revisions; 16 MiB for listings, manifests and
everything else), so a server cannot make the client buffer more.

**Write-once files.** For each note the run compares the local and remote file
sets with the set recorded at the last sync (`SyncState.files`):

| local | remote | in last sync | action |
| --- | --- | --- | --- |
| yes | no | no | upload (`If-None-Match: *`) |
| no | yes | no | download |
| yes | no | yes | the server dropped it: delete locally if compaction allows, else upload it again |
| no | yes | yes | this side dropped it: delete remotely if compaction allows, else download it again |

An existing file is never overwritten on either side. Downloads go to a
`.sempere-tmp-<uuid>` file in the target directory, are fsynced, and are
linked into place with `link(2)` (fails if the name exists), so a partial file
never appears under its final name and a file that showed up meanwhile wins.

**Compaction deletes.** Sync never decides on its own to delete. A removed file
is deleted on the other side only if `CompactionPlanner.deletable` says so,
with retention 0 (the side that removed it already applied the retention
window) over the revisions held locally: a delta needs a snapshot that covers it,
a snapshot needs one that subsumes it. The covering snapshot must be one the
remote side holds: on the server (as listed at the start of the run) for a file
the server dropped, since a compaction there keeps its covering snapshot there,
and also on the server for a remote delete. A file the server dropped is also
held to what any compactor or thinner of this format guarantees (format.md §5.3,
§5.8.4; security review stage 4, S2), since the server needs no key to drop
files: never a checkpoint or the created anchor
(`CompactionPlanner.neverDeleted`), never a set that would leave a complete
checkpoint incomplete (`deletionKeepsCheckpoints`: its positioned snapshots and
witnesses stay), and nothing in a note with an unreadable revision. Its age is
not judged: thinning everything except checkpoints is a legitimate action. An emptied or recreated remote
folder therefore deletes nothing locally; its files are uploaded again. A snapshot removed locally can only be judged from
the `included` coverage recorded when it was last synced. Without an unlocked
vault nothing can be checked, so nothing is deleted. A removal that fails the
check is undone (the file is copied back).

A deletion settled this way is remembered in the state (`thinned`) once
neither side holds the file. If it comes back on one side only (another device
or another remote brought it back), it is not copied as a new file: it is
fetched if it is on the server, and judged again with its content over every
revision both sides hold, by the rules above; explained, it is deleted from
both sides, else it is copied and forgotten. This is what lets two devices sync
the same two remotes: without it, one deleted a thinned delta from a remote
while the other uploaded it there again from the other remote, for ever
(docs/design/device-first-sync.md §5.4).

**Attachment blobs** (`docs/attachments.md` §4). Each note's `att/` follows
the same write-once table, keyed `<noteId>/att/<name>` in the state. A note
whose listing has an `att` collection costs one more PROPFIND. Per note,
blobs are transferred before revisions, so a revision does not arrive before
the blobs it references (format.md §8.1.4 step 4) unless a blob transfer
fails: that one is reported and retried by the next run while the note's
revisions still sync, and readers draw a placeholder for it meanwhile
(§8.5.2). Small kinds go first (transcripts, images, PDFs, then the rest), smaller files first.

- *Streaming, own limit.* An upload is a PUT streamed from the file. A
  download is a series of `Range` GETs of 2 MiB (`blobSegmentBytes`), each
  streamed to a partial file, so memory stays bounded by one segment even
  when the server is faster than the disk (on Linux, URLSession queues every
  delivery for its delegate without flow control; with 2 MiB segments the
  resident set stayed near 20 MiB for blobs of 300 MB to 1 GB against a
  local wsgidav). A server that ignores `Range` sends the file in one
  streamed 200, which is still written to disk as it arrives but, on Linux,
  is no longer bounded in memory by the segment size. Blob files have their own limit, `maxBlobBytes` (default
  1 GiB + 64 MiB, `--max-blob-mib`): a larger one is neither uploaded nor
  downloaded, and a body is cut off at the limit whatever the listing said.
  A downloaded blob must have the listed size and start with the age header,
  or it is not written. With the vault unlocked it is then decrypted whole
  and checked (framing, padding, hash, keyed name: format.md §9.1) before it
  is linked into place; one that fails is quarantined, never placed.
- *Write-once on the server.* An upload goes to `att/.sempere-tmp-<uuid>`
  (`If-None-Match: *`) and is renamed with `MOVE` and `Overwrite: F`, so no
  reader sees a partial blob under its name (a server that writes PUT bodies
  in place would show one) and an existing blob is never replaced; losing
  that race is success, since the name is keyed by the content hash. The
  temporary name is recorded in the state before the upload and deleted
  afterwards, or by the next run if this one dies. Other devices' temporary
  names are skipped silently.
- *Resumable.* A download goes to `att/.sempere-tmp-part-<name>` and is linked
  into place (`link(2)`). If the run is cut off, the partial file stays and
  the remote ETag is recorded in the state (saved at once); the next run asks
  for the rest with `Range` and `If-Range: <etag>`, so a blob replaced on the
  server meanwhile comes whole again. Only a strong ETag is a validator: with
  a weak (`W/"…"`) or missing one nothing is resumed, the download starts
  over, and its segments are not validated against each other (the checks
  before placing still apply). A partial file as long as the listing
  says is only checked and placed. A partial file whose blob is no longer
  wanted is removed. Uploads restart from the beginning (WebDAV has no
  standard partial PUT), but only the blob that was cut off. A run killed at
  any request is finished by the next one (`BlobResumeTests`).
- *GC-safe deletes.* A blob one side dropped since the last sync is deleted
  on the other side only if format.md §8.1.6 rules 1–3 hold for its note
  there (the side that dropped it applied rule 4): every local revision of
  the note was read and verified and every revision the server holds is one
  of them (they are byte-identical copies, so both sides' sets were read);
  no `rewrap-journal.json` on either side; and no revision read references a
  content hash whose keyed name is the blob's (any kind). Otherwise the blob
  is copied back. A blob the server dropped also needs rule 4 as this device
  sees it (security review 2026-10, S2 for blobs): the deletion is followed
  only once this device has found the blob collectable for
  `blobRetention` (the compaction retention, 30 days), from the first run that
  found it so, with every run since agreeing (`unreferencedSince` in the sync
  state). Until then it is kept here and not uploaded again (nothing
  references it), and listed as skipped; a run that finds it referenced (a
  delta that was still in flight) uploads it again and forgets the date. A
  server, which holds no key, can therefore not make devices delete a blob
  sooner than a collector of this format could. A side with no `att/` at all (a wiped or recreated
  folder) deletes nothing on the other. With the vault locked nothing is
  checked: the blob is neither deleted nor copied back, and is listed as
  skipped.

`sempere-index.json` lists revisions only (`docs/web-viewer.md`), so blobs do
not change it; the run still rewrites the server's copy to list the
revisions the server holds afterwards.

**Mutable files.** `vault.json` and `rewrap-journal.json` are compared by
content hash (SHA-256) against the last-synced hash; the server ETag (or
Last-Modified) is only recorded to send `If-Match` on upload. Local only
changed: PUT with `If-Match` (without it when the server's ETag is weak,
`W/"…"`, which never matches `If-Match`). Remote only changed: atomic replace. Both
changed (or no common ancestor and different content): the remote copy is
saved as `<name>.conflict-<device>-<yyyymmddThhmmssZ>.<ext>` in the vault root
(not again if an identical one exists), nothing else changes, and the
conflict is reported on every run until the files agree. A PUT rejected with
412 is judged by the bytes, not the ETag: the server copy is read again, and
only different bytes are a change there (then both changed, as above); an
ETag that moved over the same bytes is retried with the new one (3 tries, then
the upload waits for a later run, listed as skipped), so no conflict copy
identical to the server's is ever made. Two `vault.json` versions that differ only in `label`
(a vault renamed on two devices) are the same vault (format.md §1.3), not a
conflict: the server's copy, the one every device shares, is taken (as
iCloud Drive's current version stays), and a push-only run keeps it on the
server and lists it as skipped. `rewrap-journal.json` deleted locally is not restored
locally. It is deleted on the server only when it is the copy this device
synced (same ETag, same bytes), the vault is unlocked, this device now refuses
it (format.md §3.3.1: its change finished, nothing binds it) and the server's
`vault.json` is the local one; the DELETE carries `If-Match` with its strong
ETag, so a journal changed meanwhile stays. Otherwise (locked, or an
unfinished change this device still accepts) it is left there and listed as
skipped; one this device refuses never holds its own blob collection back.
`settings.age` (format.md §13) is merged instead when both sides changed and
the vault is unlocked: both copies are opened (tag verified), merged per key,
and the result written locally and uploaded with `If-Match` (`merged` in the
report; a 412 is merged on the next run). A copy that does not verify never
replaces one that does, and is replaced by it. A copy that needs a newer reader
(`$minReaderVersion`) is never opened: it is mirrored byte for byte over a copy
this version can read; two such copies that differ follow the conflict rule
above, as does the file while the vault is locked. A run that pulled a new `vault.json`
(a key change elsewhere) leaves `settings.age` to the next run, which opens the
vault with the new secret.
`rewrap-journal.json` from the server never replaces a local one unless this
device refuses the local one and accepts the server's (`Vault.incomingJournalProblem`,
format.md §3.3.1 "Refused journals"; security review stage 4, S9): an unfinished
local journal may be the only copy of the outgoing secret. Without the key the
server's copy is kept as a conflict copy instead. With the key, a server journal
this device refuses (planted, or put back after its change finished) is listed in
`rejected` and not written, and does not hold blob collection back. A journal is
judged under the local `vault.json` as this run left it: with none yet (a first
pull whose `vault.json` did not arrive) it is not taken but waits for the next
run, and a first pull with identities (`firstPullIdentities`) judges it under
the pulled `vault.json` with them. A refused journal that may be step 1 of a
recipient change whose `vault.json` has not reached the server yet
(`Vault.incomingJournalMayBeInFlight`: the local `vault.json` has no
`rewrapPending`, and the journal holds no outgoing secret, or one this device
cannot decrypt, or the current one) is held for `Vault.inFlightJournalWindow`
(a day) from this device's first sighting (`inFlightJournal` in the sync
state): not taken, not rejected, listed as skipped, still holding blob
collection back (rule 2), and judged again every run, so it is taken once its
`vault.json` arrives. After the window it is rejected as above.
Before a remote `vault.json` replaces the local one, its device list is
checked (`Vault.incomingManifestProblem`, format.md §2.1): the same keys
(still tagged) pass without a key; a changed list passes only when the vault
is unlocked and the list verifies (tag under the secret it carries, that
secret the local one or confirmed by `secretLink`), and, under the same secret and list,
it never brings back or changes `rewrapPending` (a `vault.json` put back to
replay a finished change's journal). Otherwise it is listed in
`rejected`, the local file stays and the sync state is not updated, so the
next run reports it again.

**The capture inbox** (`InboxSync.swift`, format.md §11.4, design §5.3). Inbox files are deleted
once adopted and re-sealed by a key change, so they are not write-once. A file on one side only is
copied over (create only; on a remote without atomic creates, through a temporary name and a move,
as blobs are, so a reader never sees half of a 256 MiB capture), and a received one is downloaded into
a hidden staging folder in `inbox/`, checked there (unlocked: `Vault.checkIncomingInboxFile`, the tag
under the capture key ring and the manifest, as adoption reads it; locked: its age structure) and
linked into place, or quarantined. A file on one side only that adoption explains is deleted from that
side, never copied: the note derived from its capture id has a revision here, is complete, and adoption
deletes that file after it (`CaptureAdoption.consumed`; for a transcript, judged with its bytes).
Adoption would delete it there anyway, and two devices that bridge two targets would otherwise hand an
adopted capture back and forth for ever (found by the N-device stress run). A file both sides held at
the last run (`SyncState.inbox`) that one side lacks now, and that adoption does not explain, is copied
back. A locked run uploads (quick captures into a closed vault) and downloads files never synced, but judges no deletion. The
inbox is synced after the notes, so an adopted note reaches each side before its inbox files go. A
file on both sides with different bytes (a key change re-sealed one) is reported in `skipped` and
neither copy is replaced (that is rewrap-replace, key hierarchy KH6). Unchanged files are recognized
by the remote's version token and the local size and modification time, so a large capture is not
hashed or fetched again every run. Push-only runs upload and follow explained deletions on the
server, never write locally.

**Per-device summaries** (`DeviceSummariesSync.swift`, format.md §12.5). `summaries/<device>.sealed`
is written only by its device. This device's own file (`SyncOptions.deviceID`; the CLI's device id
when it has one) replaces the remote's whenever they differ and is never taken from the remote.
Another device's file is copied to the side that lacks it; when both sides hold different copies,
the side that changed since the last run (`SyncState.deviceSummaries`) wins, the remote's if both did,
so a device with two targets carries a newer copy from one to the other. A received file is placed
only when it starts with `SMPU` `0x01` and, unlocked, opens under the vault's secret; otherwise it is
listed in `skipped` (a hint, not quarantined: after a key change an older file is only stale).
Nothing is deleted.

**Push-only mirror** (`--push-only`, `SyncOptions.pushOnly`). A two-way
sync rejects a `vault.json` whose recipients changed without a valid tag
(format.md §2.1, above), but it still takes whatever else the server holds:
new revisions and blobs, deletions it can explain, journals. For a server that
is only a copy (the web viewer's mirror) and is not trusted to write back, the
run is one-way, and the server can be corrupted but can never feed anything
back:

- nothing is downloaded, and nothing in the vault folder is written, restored
  or deleted (every local write path refuses in this mode; only the sync-state
  file outside the vault changes);
- a file the server lacks is uploaded, including one the last sync had;
- `vault.json` and `rewrap-journal.json` on the server are replaced by the
  local copy when they differ (reported in `overwritten`); a malformed server
  manifest is repaired the same way, one of another vault still aborts;
- a file only the server has is deleted there if it was synced before and the
  compaction (`CompactionPlanner`) or blob collection (§8.1.6 rules 1–3) rules
  explain its absence locally, exactly as in the table above;
- one synced before but not explained (or unjudgeable with the vault locked) is
  kept and listed as skipped: a local listing can miss files, notably evicted
  iCloud ones;
- one never synced and not explained (injected revision or blob, a stray
  journal, junk names) is `extraneous`: reported, and removed only with
  `--delete-extraneous`, and only when sync state from an earlier run exists:
  on a first run every server file looks never synced, including those of a
  note the local listing missed, so they are only listed (as skipped). The
  flag can still delete a legitimate file another writer added since.

**Limits.** A recipient change rewrites files under `notes/` in place
(format.md §3.3), which sync never propagates: after one, pull into a fresh
folder from a new collection (or upload the rewritten vault to a new one) and
retire the old one. `rewrap-journal.json` left on the server by a finished
change stays there; devices refuse it (`vault.json` no longer binds it, format.md
§3.3.1), and `--push-only --delete-extraneous` removes it. Syncing during an unfinished rewrap can
copy a mix of old and new files.

**Bounds per run** (`SyncLimits`, security review 2026-10, W5). Each
request is bounded on its own; the run as a whole is bounded too: at most
100 000 note folders listed, 10⁶ remote entries listed (root, note folders,
`att/`), 64 GiB downloaded and 12 hours (`--max-notes`, `--max-entries`,
`--max-download-mib`, `--max-minutes`). Time is checked before each note and
each download, and a request in flight is canceled once the time is up
(`WebDAVRequest.interrupt`, polled a few times a second; a cancellation,
`isCancelled`, stops it the same way): a server that trickles a response,
never idle long enough for the idle timeout, cannot hold a run past its bound,
and a cut blob download keeps its partial file. Bytes are checked before (from the listing) and after each download.
Reaching a bound stops the run: the error says which (`stoppedEarly` in the
JSON report), what was done is recorded in the state, and the next run
continues from there. A note folder whose listing fails is an error for that
note: nothing is judged for it this run and its records are kept. A run that
did not list every note folder leaves the server's `sempere-index.json` and
`sempere-summaries.sealed` as they are.

**State.** `$XDG_STATE_HOME/sempere/sync/<hash of URL and vault path>.json`:
file names, hashes, ETags and snapshot coverage, no secrets. Deleting it makes
the next run a first sync: nothing is deleted, nothing overwritten. It is
saved at the end of a run. Before each blob transfer only the transfers in
flight (temporary upload names, partial downloads) are saved, to
`<state>.json.transfers` beside it; the next run takes them in, and the
end-of-run save removes that file. A killed run's other progress is found on
both sides by the next run.

**Concurrent transfers and progress** (`TransferPool`, `Prefetch.swift`).
On a high-latency link round trips dominate (a first pull of ~800 files
makes ~2 000 requests), so the note folders, then their `att/`, are listed `concurrency` at a time
(`SyncOptions.concurrency`, `--jobs`, default 6, 1 to 16), and a
two-way run downloads what the note loop would download as new on the
server (each note's revisions and blobs that neither the vault holds nor the
last sync recorded) the same number at a time, before the note loop: a
note's blobs first, its revisions only once they all finished (format.md
§8.1.4 step 4). Each download is the one the note loop makes, with every
check, quarantine and resume; what it shares with the run (state, report,
budget) is under one lock. Run bounds hold across threads: listed sizes are
reserved before each download, and the first bound reached, or a
cancellation (`isCancelled`, asked before each listing, note and download and
between blob segments), stops the pool: no new transfer starts, the running
ones finish (a blob stops at its next segment and keeps its partial file),
and the run stops early as it would one at a time. The note loop then runs
as usual; what the prefetch tried and failed is reported once and not tried
again in the same run. Uploads work the same way (`Preupload.swift`): before
the note loop, what it would upload as new on this side (a two-way run: what
the server's listing lacks and the last sync did not record; a push-only run:
what the listing lacks) is uploaded the same number at a time, a note's blobs
first and its revisions once they all finished, each through the note loop's
own `upload` / `uploadBlob` (`If-None-Match: *`; a blob to a temporary name,
then `MOVE` without overwrite), so nothing on the server is ever replaced.
The note loop counts those as its own uploads (also for the folder-ETag check
of "Unchanged notes"), decides deletions and restores exactly as before, and
does not try a failed one again in the same run. Revisions over 8 MiB, read
whole to upload, are left to the note loop. Reports are sorted by path where
the prefetch or the uploads added to them, so they do not depend on thread
timing. Deletions and the mutable files stay one at a time. The transport
keeps one connection per transfer alive between requests
(`httpMaximumConnectionsPerHost` 16, the most `--jobs` allows; URLSession's
default of 6 queued the rest). `SyncOptions.progress` gets a
`SyncProgress` (stage; notes listed and synced; files and bytes
downloaded of the total, known once every note folder was listed; uploads)
from the run's threads, one call at a time; the final value is in the
report's `progress`. Counts only grow: a file counts as done once it is
placed (one that failed, was quarantined or was cut short does not), and its
bytes never more than its listed size, even when a server answers a resumed
request with the whole file. Partial pulls ("Partial copies") have their
own concurrency (`FetchScope.concurrency`) and report the same
progress: the metadata pull its note count, a fetch the files and bytes it
fetches and the notes it went through; a fetch stops between notes on a
cancellation.

**Unchanged notes.** With `skipUnchangedNotes` (`--skip-unchanged`; the
app's runs) a run does not list a note folder whose ETag in the `notes/`
listing is the one recorded when the last run left that note in step on
both sides, when the local folder holds exactly the recorded revisions (and
no blob when the server had no `att/`); it takes the recorded revisions as
the server's. A note's `att/` is listed every run, since many servers change
a folder's ETag only for its direct children. It is trusted only where it
is seen to work: after this device writes a revision into a note folder,
the next run checks that folder's ETag changed; one check that passes
enables it, one that fails disables it for good (until the state is
deleted). Weak (`W/`) and missing ETags are never recorded. Any doubt in a
note's run (an error, a skipped, ignored or extraneous file, a file on one
side only, a write) clears its record so the next run lists it, and a run
lists every note at least every `fullListingInterval` (a day).

**One listing for every note folder** (`deepListing`, `TreeListing.swift`;
off with `--no-deep-listing`). Listing each note folder and each `att/` costs a
request apiece every run (~685 for a vault of 640 notes, even when nothing
changed). `PROPFIND` with `Depth: infinity` on `notes/` gives the same entries
in one request where the server allows it; many refuse it (Apache's default)
and some answer it as `Depth: 1` (Sabre/Nextcloud with infinite depth off), so
it is trusted only where it is seen to work. A run that has not seen it work
asks for the tree once and compares it with the listing of a sample of
`verifySample` (16) note folders and their `att/`, spread over the vault, taking
the other folders from the tree in the same run (a vault of 640 notes: about
20 requests); a vault with no more folders than that, or a sample that differs
from the tree, is listed one by one as before. When every note
folder and `att/` it listed holds exactly what the tree says, the server is
recorded (`treeListing` in the sync state) as answering in full. A refusal (a
4xx such as 403 `propfind-finite-depth`, a 501, or an answer with nothing below
the note folders) is recorded for good, until the state is deleted; any other
difference (another device writing between the two) records nothing and the
next run checks again. Runs within `fullListingInterval` (a day) of the last
check take every note folder and `att/` from the tree: the root, `notes/` and
the tree, three PROPFINDs whatever the vault's size; a later run checks again.
Only with 8 to 5 000 note folders (below, the requests saved are few; above,
the answer nears the 16 MiB listing bound). A tree request that fails (5xx, a
cut connection, too large) falls back to one-by-one listings for that run. A
tree that missed files (a server whose behavior changed since the check) loses
nothing: the server is untrusted anyway, and a file it does not list is one it
dropped (uploaded again, or a revision deleted here only when compaction
explains it from snapshots the server lists, as above).

**Partial copies** (format.md §1.2). A vault can be opened from
its root files and note list and filled later, so a large vault (~1 GB,
~800 files) is usable after a few requests. The state is
in the vault folder itself, not in the sync state: `.sempere-partial/` at the
root (its `record.json` says whether the note list is complete; the server's
`sempere-summaries.sealed` is kept there as `summaries.sealed`), a
`.sempere-pending` marker in each note folder whose revisions have not all
arrived, and `att/.<blob>.sempere-pending` for each blob not fetched. Three
kinds of run (`SyncOptions.partial`, `LocalCopy`):

- *Metadata pull* (`.metadata`, `downloadMetadata`, `sempere sync webdav
  --metadata-only`): marks the folder partial first (so an interrupted pull
  never looks complete), takes `vault.json`, the journal and `settings.age`
  as a two-way pull does (same checks), fetches the server's sealed summaries
  into `.sempere-partial/` (bounded at 64 MiB, opened only by a reader with the
  key, never trusted beyond that: a missing or unreadable one only means notes
  are listed as they arrive), lists `notes/` (one PROPFIND) and makes one
  marked folder per note. Three to four requests whatever the vault's size;
  nothing is uploaded or deleted. The copy is *usable* once a run listed every
  note folder (`record.json` `listed`); until then it is not opened and no
  fetch runs. Until then every server note is marked whatever its folder
  holds, so files already there (linked in by a re-download, `LocalCopy.redownload`, or left by an
  unfinished full download) are only a head start; a later metadata pull marks
  only notes it has no folder for. It refuses a complete vault (marking its
  notes would block edits to them).
- *Fetch* (`.fetch(FetchScope)`, `fetch`, `--fetch [--note ID]
  [--no-blobs]`): for each note in scope (the ones asked for first; every
  incomplete note by default; `maxNotes` per run so a push never waits long for
  the sync state), lists its folder and `att/` on the server *as they are now*
  (concurrently, `concurrency`, default 4), downloads every revision there that
  the folder lacks (revisions up to 8 MiB concurrently, larger ones one at a
  time, so memory stays below 32 MiB plus one revision), checks each as any
  download is (format.md §9.1: fully with the vault unlocked, else its age
  structure; a refused one is quarantined and reported, and counts as
  settled, as in a full download: the note opens without it and the copy can
  complete; later runs list it under `skipped` until it changes on the server
  or `--retry-quarantined`; a refused blob likewise gets no stand-in),
  then either downloads the note's blobs (`blobs: .all` or `.only`, streamed and
  resumable as above) or leaves a stand-in for each one it lacks, removes
  stand-ins of blobs the server no longer has, records what both sides now
  hold in the sync state, and only then removes the note's marker. A note
  whose folder is gone from the server loses its stub (if it holds no
  revision), but only once `notes/` no longer lists it either: a 404 for a
  folder `notes/` still lists (or cannot confirm) keeps the stub marked and is
  reported as an error, so the next run tries again (otherwise the note would
  be missing here and, once the copy is complete, look extraneous to a
  `--delete-extraneous` mirror). When nothing is pending, `.sempere-partial/` goes: the copy is
  complete. A fetch never uploads, never deletes anything on the server, never
  writes a root file and never touches a complete note's revisions, so it
  runs while the copy is open and edited.
- *Ordinary runs*. A two-way sync completes a partial copy (it downloads what
  is missing, then removes markers and stand-ins as each note settles). A
  push-only run (the app's pushes) treats what the copy lacks as pending: in
  an incomplete note nothing is judged for deletion and server-only files are
  kept (counted in `partial.keptOnServer`, never `extraneous`); a blob with a
  stand-in likewise. `--delete-extraneous` is refused while the copy is
  partial. The server's `sempere-summaries.sealed` is not rewritten while a
  note is incomplete (its entries come from the local notes and would drop
  the missing ones); `sempere-index.json` lists the server's files and still is.

Why a push from a partial copy can delete nothing it has not fetched: a push
deletes on the server only a file it recorded as synced (on both sides) and
that compaction or blob collection explains locally; a file the copy never
held is never recorded (a fetch records only what it placed). Writers refuse
incomplete notes (format.md §1.2), so no local compaction, thinning or blob
collection runs where files are missing. The guarantee is property-tested
(`PartialCopyTests.testRandomInterleavingsNeverLoseAServerFile`: fetches of
random scopes, pushes, local edits, another device writing and injected
request failures, in random order; the server never loses a file) and run
against wsgidav (`testPartialCopyLifecycle`, `CLIWebDAVTests.testPartialCopyAgainstRealServer`).

*Interruptions.* A metadata pull cut off leaves the copy unusable; the next
one continues. A fetch cut off leaves the notes it had not finished marked
(their placed revisions stay), and a blob cut off resumes from its partial
file (`If-Range`, as above). A push in between changes nothing on the server
but uploads.

*Other writers.* Notes another device writes after the metadata pull reach
an incomplete note when it is fetched (its folder is listed then); a note
already complete, or one created after the pull, arrives only by downloading
again, as for any copy. Compaction elsewhere is fine: a fetch takes the
note's folder as it is.

*Whole-vault work on a partial copy.* The CLI refuses what must see every
file: `export --all`, bulk export, `backup`, `search`, `compact --all`, `blobs`
over every note, `recognize --all`, `transcribe --all`, `vault index`, `vault
summaries`, and device key changes (core refuses those). `notes show`, edits
and everything else naming an incomplete note fail with "not completely
downloaded"; `notes list` shows such notes with that problem. The app fetches
what it needs instead (below).

**Testing.** `scripts/test-webdav.sh` starts a local wsgidav
(`pip install -r scripts/webdav-server-requirements.txt`, the pinned versions;
the script refuses another wsgidav unless `SEMPERE_WEBDAV_ANY_SERVER=1`) and runs
the integration tests, which are skipped unless `SEMPERE_WEBDAV_TEST_URL` is
set; the script sets it and fails if any of them skipped. CI runs the script on
every change to the package, in the `webdav` job (Linux) and at the end of the
`macos` job (the large-blob test at 64 MB: `SEMPERE_WEBDAV_LARGE_MB`). Both
matter: Apple's URLSession, revalidating from an HTTP cache, adds
`If-None-Match` to a DELETE, which wsgidav 4.3.5 answers with 412 (compaction
would never reach the server, `testTwoVaultsThroughOneServer`), while
FoundationNetworking on Linux sends no such header. The transport keeps no
cache, and the pinned 4.3.5 refuses such a request, so the macOS job catches
a regression the Linux job cannot.

## Sync targets in the app

Every in-app vault (the store, docs/design/device-first-sync.md §2) can have any number of sync
targets, and every vault with one keeps syncing, open or not, each isolated from the others (§4.2).
The app only ever reads and writes the in-app copy, on every platform; targets are outside copies it
syncs with both ways.

- **Targets** are `SyncTarget`s in the store's registry (`SyncTargetRegistry`,
  `<store>/.sync/<vault id>/targets.json`, shared with `sempere store target`): a **folder** (iCloud
  Drive, another provider's folder, a drive, a share, any folder; the app keeps a bookmark of the folder
  the user picked, `options: []`, and the copy's subfolder) or a **WebDAV** server folder (its password in
  the Keychain under the target's id). The kind is an open string, so a later transport (§3.4) adds a
  kind, and a target of a kind this version does not know is listed, never run. Each target's sync
  state, quarantine and transfers live in `<store>/.sync/<vault id>/<target id>/`; removing the vault
  removes them, removing a target never touches the folder or server.
- **The store's place**: on an iPhone or iPad `<App Group>/Library/Application Support/Sempere/Vaults`
  (`VaultStoreRoot`, `completeUntilFirstUserAuthentication`), so voice notes reach the inbox from the
  Lock Screen; on a Mac `Application Support/Sempere/Vaults` in the app's container (no App Group
  entitlement there). A store an earlier build left in Application Support moves over once.
- **Setting up.** New Vault's "Keep a Copy In" (none, or a folder), "Open Vault…" (`OpenVaultSheet`:
  the vault is copied in; "Keep syncing with this folder", on by default for iCloud Drive and other
  providers' folders, off for a local folder such as an export, makes the folder a target; on a vault
  already in the store it adds the folder to that copy), connecting to a WebDAV server (a store vault
  with a WebDAV target, below), and File ▸ Sync Targets… / the sidebar's More menu (`SyncTargetsSheet`:
  every target with its status, Add Folder…, Sync Now, Remove). A picked folder that holds a vault is
  the target; any other folder gets the copy in `<picked>/<name>.sempere`, made by the first run. Adding
  a target to a vault that has notes is a union: the first run copies what either side lacks and
  deletes nothing. The same place twice is refused, and so is a folder inside the store.
- **Folder runs** (`FolderTargetRun`, the same as `sempere store sync`): the engine over `FolderRemote`
  with the provider's hooks (`FolderProviders.detect`: iCloud Drive and other providers are coordinated,
  evicted files and folders listed before their files are *arriving*, conflict versions are merged or
  kept and resolved; docs/io.md "Folder targets in providers"), two-way while the vault is open and
  unlocked here, upload-only otherwise, waiting at most `folderArrivalWait` (10 s) per run for files a
  provider is downloading. A folder synced before that is gone is not recreated ("The folder is gone…
  Choose it again", nothing deleted here); one whose parent is gone (a drive not connected, a dead
  bookmark) is offline. Folder targets run 2 s after a write and every minute.
- **Voice notes** go to the one vault their capture profile names: straight into its in-app inbox,
  found in the store by vault id whatever the profile's bookmark says, open or not; its targets upload
  them at once (`QuickCapture.delivered` → `SyncCoordinator.vaultWritten`).
- **Key changes** are refused in the app for a vault with any target (`requireLocalKeyChanges`) until the
  key hierarchy's phases land: a rewrap in place reaches no target.
- **`SyncCoordinator`** (one per app, started at launch) owns one `SyncSession` per (vault, target). The
  open vault's sessions run two-way while the vault is unlocked here; every other session runs
  upload-only. At most two runs go at once across the app (`maxConcurrentRuns`), at most one per
  session, the open vault's first; two targets of one vault take turns on the vault's write lock, and a
  device with two targets bridges them. Each session has its own sync state, quarantine,
  credentials, schedule, backoff and status: one vault's wrong
  password, hung server (bounded by the run's limits) or full disk never delays or fails another
  (`SyncCoordinatorTests`).
- **When** (`SyncSchedule`, pure, in `SempereSync`): once at the start and after the unlock (two-way
  from then on), `writeDelay` (10 s) after the last write (every `NoteWriter` delta and blob counts),
  when the app becomes active (every session) and when it goes to the background, and on "Sync Now".
  Otherwise every 30 s while the last run brought something or left files arriving, then 5 minutes,
  doubling with each run that changed nothing up to 15 minutes. After a failure, 30 s doubling up to
  15 minutes; a write or a demand still runs sooner. At most one run at a time; a write during a run
  schedules another. Background tasks for closed vaults come with P8.
- **Arrivals** (`LocalChanges`, the report's `changed`): what a two-way run wrote in the copy. The
  notes it touched are listed again (`reconcile(scope:)`, only those), and an open editor of one
  merges the new revisions in place (`AppModel+RemoteMerge`, as for any listing); `settings.age`
  taken or merged runs the settings pass (`SettingsSyncBridge` applies it); inbox files start
  adoption; notebook records reload the tree; other devices' published summaries refresh the rows of
  notes not here yet. A new `vault.json` with another device list or secret (a key change made with
  the CLI elsewhere) saves and closes every editor and opens the vault again with this device's keys,
  as after a key change made here (`keyEpoch`); if this device's key is no longer listed, the vault
  closes and says so. A label alone changes nothing.
- **The write lock** (`VaultStore.writeLock`, `<store>/.locks/<vault id>.write`, the lock every writer of
  the vault on the device takes, the CLI's included): a run holds it while it settles and
  replaces the copy's mutable files (`vault.json`, the journal, `settings.age`;
  `SyncOptions.localWriteLock`), and the model holds it while it writes `settings.age`, so a merge
  never interleaves with the app's own write. A run that cannot take it within 30 s leaves those
  files to the next run (listed as skipped). Revisions and blobs are write-once and need no lock.
- **Status** (`SyncStatus`, the note list's bar): syncing; synced (and how many files a provider
  still delivers); "n changes not synced yet"; offline ("Changes are kept on this device and sync
  when the server can be reached", not an error); waiting for the unlock (a closed or locked vault);
  or the problem and what to do (wrong password, certificate, the folder gone or holding another
  vault, a device list changed on both sides, files that failed). The menu has Sync Now and Server
  Settings…; "Download Again" is gone, since a run takes what the server has.
- **Other writers.** Several devices write to one server folder; their files meet by the engine's
  union rules (docs/design/device-first-sync.md §5), conflicts on `vault.json` keep both copies and
  are reported. Tests: `TwoDeviceSyncAppTests` (two `AppModel`s on one in-memory server running the
  real engine: a note and a rename reaching the other device's list and open editor, edits made
  offline on both, settings, a 6 MB attachment, runs cut midway, a server folder that vanishes and
  comes back empty, a vault reopened while a run goes, a closed vault that only uploads);
  `FolderTargetAppTests` (two devices through one folder under `EvictingFolderProvider`: notes and an
  open editor's merge, a target folder deleted or unreachable, files evicted while runs go, a
  provider's conflict copy, two targets bridged by one device and a new target that gets every note,
  a voice note recorded while its vault is closed, the store's move and old WebDAV copies carried
  over).

## WebDAV vaults in the app

For people with no Mac and no iCloud, the app keeps a vault on a WebDAV
server it talks to itself (`Open Vault ▸ WebDAV…`). It wraps the same
`SempereSync` engine and `SempereWebDAV` transport as `sempere sync webdav`; nothing about the server
side changes, and any server the CLI works with works here.

**One transport per connection.** `LiveWebDAVRemote` keeps a single `URLSessionTransport` in a
`WebDAVTransportPool`, keyed by URL, user, password and pin, so consecutive runs and fetches reuse its
TCP/TLS connections. A different key replaces it (trust is decided by that transport's own
`PinnedServerTrust`, built from the key's pin, so a pin is never evaluated under another); closing the vault
(`stopWebDAV`) empties the pool. A dropped transport is not killed: operations still holding it finish, and
its sessions invalidate in `deinit` (`finishTasksAndInvalidate`). "Test Connection" builds its own transport
(it needs the certificate recorder).

**Model: a store vault with a WebDAV target, synced both ways.** The vault the app opens is a store
vault (`<store>/<vault id>/<name>.sempere`) and the server one of its targets (`WebDAVLocationStore` is
the WebDAV view of the target registry; sync state and quarantine in the target's own folder). The first
download builds it in the store. WebDAV copies of earlier builds (`Application Support/Sempere/WebDAV/`,
`webdav.json`) become store vaults at launch (`LegacyWebDAV`): the copy moves into the store, its sync state
and quarantine to the target's folder (so the first run neither uploads nor checks everything again), and the
target keeps the location's id, so the Keychain password still applies; a copy whose vault the store already
holds becomes one more target of that vault, and an old copy holding changes the server never confirmed is
left where it was. Connecting to a server whose vault is already on this device adds the server as a
target of that vault (the first run is a union). Every read and
write goes to that copy through the usual plain-folder paths (no iCloud
code runs for it), so the app works offline exactly as with a vault on the
device. The server is kept in step by two-way runs of the engine
(`LocalCopy.sync`, "Sync targets in the app" below) while the vault is open
and unlocked: they take what other devices wrote (every file checked before
it is placed, format.md §9.1), merge `settings.age`, upload what this device
wrote and follow the deletions the rules explain. While the vault is closed
or locked, its runs only upload (`SyncOptions.pushOnly` with
`keepServerChanges`): nothing unverified is placed in a copy nobody unlocked,
and what other devices wrote arrives at the next unlock.

**Connecting** (`WebDAVConnectSheet`, logic in `WebDAVLocation`,
`WebDAVConnection`): URL, user name, password, "Test Connection".
- `https` only; plain `http` is accepted for `localhost` alone (as the CLI).
  Credentials in the URL are refused.
- The password is stored only in the Keychain (generic password, service
  `io.github.anthonytw.sempere.webdav`, account the target id,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronizable), is
  never logged and never written to a file or `UserDefaults`. The rest of the
  target (URL, user, certificate pin) is in the store's target registry
  (`<store>/.sync/<vault id>/targets.json`), holding no secret.
- The test lists the URL (PROPFIND, Depth 1) and says what it found:
  reachable and a vault; reachable with vaults one level below; reachable
  with no vault; or why not (offline, wrong user or password, not found, not
  a WebDAV server, a redirect, an untrusted certificate). The **vault list**
  is the URL itself when it holds a `vault.json`, otherwise each collection
  directly below it that holds one (at most 64 collections are looked into).
  A vault is named by its `vault.json` `label` (format.md §2) when it has
  one, else by its folder: a server folder called `dav` says nothing. The
  location and its recent-vault row take the label of the copy each time it
  is opened, so a label set later (`sempere vault label`, then a sync)
  arrives with the next two-way run.
  Names and ids from the server are untrusted: control characters are
  escaped and lengths bounded before display.
- **Self-signed certificates** need an explicit, loud opt-in. When the
  system does not trust the server's certificate, the test shows its SHA-256
  fingerprint and subject in a red warning box ("Anyone who can intercept
  this connection could present such a certificate. Trust it only if this
  fingerprint is the one your server shows.") with a "Trust This
  Certificate" button and a confirmation. What is stored is a pin of that
  exact leaf certificate (its SHA-256) for that one location: no other
  certificate, self-signed or not, is accepted for it in place of system
  trust, and a changed certificate fails with "the server's certificate
  changed" until the user trusts the new one. Evaluation happens in the app
  (`PinnedServerTrust`, Security framework) behind the library's
  `WebDAVServerTrust` hook; the CLI has no pin and relies on the system's
  trust store.

**Opening without downloading everything first** ("Partial copies"
above). Choosing a vault from the list makes a partial copy: a metadata pull
takes `vault.json`, the journal, `settings.age`, the server's sealed summaries
and the note list (a few requests, whatever the size of the vault: a
~1 GB, ~800-file vault opens in seconds), and the copy opens
locked with the usual unlock sheet. It is opened only once a metadata pull
finished without errors and listed every note (`WebDAVLocation.downloaded`,
`LocalCopy.isUsable`); one that stopped continues when the vault is
opened again. While the pull runs (and while
a re-download pulls), an overlay shows a bar with the stage and counts
("Connecting to the server…", then "Listing the server: n of n notes")
(`WebDAVDownloadStatus`, from the run's `SyncProgress` through
`WebDAVProgressRelay`) and a Cancel: the run stops after the requests in
flight, nothing is reported as an error, and opening the vault again
continues. The fill
that follows has no second overlay: it shows in the note list's bar as
"Downloading from <server>: n of m notes" (fed by the listing passes). Offline, a usable copy opens
from what it holds.

The rest arrives through the iCloud machinery, not a second one:
`WebDAVFetcher` provides the `CloudVault.Hooks` while the copy is open
(`AppModel.cloudHooks`), so the copy is an `isCloudVault` and
`ProgressiveLoad`, `downloadNote`, `CloudVault.requireLocal`, `CloudBlobs` and
`downloadEverything` work on it unchanged. The hooks read the copy's markers:
every revision of a note marked incomplete is `missing` (even those already
there: the note is read only once all are), a blob with a stand-in is
`missing`, a fetch that failed is `failed` (with the server's error); a
download request asks the fetcher for that note or blob first. The fetcher
runs library fetches (`LocalCopy.fetch`) in a background loop: notes
asked for (the one opened or selected, the ones a pass looks at) first, then
every incomplete note in batches of 12 (each run lists its notes and fetches
their small revisions four at a time), then, with "Download Attachments in
the Background" on (the WebDAV menu; on unless turned off,
`Sempere.webdavFetchAttachments`), the attachment blobs. A run that fails
waits 2 s, doubling up to a minute; asking for something wakes it. A note a run leaves as it was (still incomplete, or its blobs still pending, with or without an error) is parked: left out of the next runs for 2 s, doubling up to 10 minutes, so it is never fetched in a loop and never holds the others back, even when it is the one asked for; a new fetcher (reopening the vault, "Download Again") starts afresh. An attachment asked for that a run leaves pending is not asked for again by itself: whoever waits for it asks again or reports the stall. Each run
tells the sync loop which notes it touched (`noteFoldersChanged`), so their
rows stop spinning as soon as they are read. Fetches are checked for their
age structure while the vault is locked and fully under the key once it is
unlocked (format.md §9.1).

- *The list.* After the unlock the server's sealed summaries
  (`.sempere-partial/summaries.sealed`, opened with the key) give every note
  not downloaded yet its row (title, notebook, tags, dates, page texts, so
  search finds it), with the iCloud spinner, and the list's bar says
  "Downloading from <server>: n of m notes". Without the file (a server that
  never published it, or one this key cannot open), notes not downloaded yet
  are placeholder rows ("Downloading from <server>…") until they arrive. A
  note marked incomplete is never taken as unchanged from the device's index
  (after a re-download its folder may hold the files its indexed summary
  came from).
- *Opening and editing* a note not downloaded yet fetches it first
  (`downloadNote`), exactly as for iCloud, and the editor refuses to show a
  note whose revisions are not all there (`requireLocal`); core refuses any
  write to it anyway (format.md §1.2). Attachments are fetched when a page
  shows them or a recording plays (`CloudBlobs`), the rest in the background
  if the setting is on.
- *Search, backup, export, Recognize All, blob collection.* Search covers notes
  not downloaded yet through their published summaries; Recognize All skips
  pending notes (as for iCloud); export and bulk export fetch each note first
  (`loadNoteForExport`); a backup waits for every note and attachment
  (`downloadEverything`, then the blobs); the unused-attachments index and
  thinning decide nothing for notes not local, and core refuses blob
  collection and compaction in an incomplete note. Key changes stay refused
  for a WebDAV copy.
- *Sync runs* on a partial copy: an unlocked two-way run downloads what the copy lacks and so
  completes it ("Partial copies" above: "A two-way sync completes a partial copy"); an upload-only
  run (locked) keeps on the server everything the copy has not fetched. Nothing is deleted on the
  server because the copy lacks it. A fetch and a two-way run of the same copy never leave a blob's
  stand-in beside the blob (the fetch checks again after writing one, and the copy's completion
  removes any left).
- *Texts.* The machinery's messages name the server instead of iCloud Drive
  while a WebDAV copy is open (`CloudSource.current`).

**When it syncs, the status, other writers**: "Sync targets in the app" below.

**Not offered for a WebDAV vault in the app**: changing the vault's keys
(adding, removing or replacing a device, finishing an interrupted change). A recipient change
rewraps files in place (format.md §3.3), which sync never propagates, so the
server would keep files a removed key can read. The app says to do it with
the CLI on a folder copy and upload that to a new server folder.

**Removing** ("Remove from This Device", on the welcome screen) deletes the
local copy, its sync state, the Keychain password and the recent entry. When
the copy holds changes the server has not confirmed, the confirmation says how
many will be lost and to open the vault and sync first.

**Recents.** A WebDAV vault is a recent entry with its location id and no
bookmark (`RecentVault.webdav`), so "reopen the last vault" at launch opens
the local copy, offline too.

**Mac.** The sandboxed Mac build has `com.apple.security.network.client`
for this (`scripts/release-check.sh` lists every entitlement and why).
