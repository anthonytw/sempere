# Device-first vaults with two-way sync (proposal)

Status: **proposal**, nothing implemented. 2026-10-19.

Owner's decision (2026-10-19):

> Sync both ways. Probably switching the structure to be device first with iCloud or WebDAV sync is
> the way to go. [...] offline access is 100% necessary.

> [Keeping everything on device] takes up so little space, I can't imagine wanting to store it online
> and lose access to note taking whenever your device is in airplane mode.

> If you didn't support two-way sync on WebDAV, that means you can't sync devices across a different
> provider other than iCloud. I don't want people locked into iCloud. WebDAV should have first-class
> support.

## 0. Recommendation in brief

1. **Every vault is a complete local folder**: in the App Group container on iOS and iPadOS, and on the
   Mac in the container or a local folder the user picks. The app reads and writes only that folder,
   with no coordination, placeholders or download waits. Everything works offline, always.
2. **Sync targets are optional and provider-neutral.** A target is a *remote* (anything that stores a
   copy of the vault layout) plus that device's sync state. The two first-class kinds are **iCloud
   Drive** and **WebDAV**, and they have the same features, status, scheduling, conflict handling and
   join flow. "Another folder" (Proton Drive, a USB drive, a NAS share) comes free with the iCloud
   folder transport.
3. **One engine.** The two-way engine that `SempereWebDAV` already has (`WebDAVSync`, with partial
   pulls, quarantine, bounds and resumable blobs) moves to a new network-free target, `SempereSync`,
   and runs over a small `SyncRemote` protocol. WebDAV becomes one adapter. A **folder adapter**
   (Linux-portable, with Darwin hooks for coordination, download requests and conflict versions)
   serves iCloud Drive and any other provider. The CLI gets `sempere sync folder PATH`.
4. **The engine gains what parity needs**: sync of `inbox/`, `keys/` and `summaries/<device>.sealed`;
   and a **rewrap-replace rule**, so a key change propagates through any target. This removes the
   app's refusal of key changes for WebDAV vaults.
5. **Arrivals reuse what exists**: the engine reports the note folders it changed, and that report goes
   into `noteFoldersChanged`, which drives reconcile and `AppModel+RemoteMerge`.
6. **iCloud gets the WebDAV guarantees**: every received file is checked before it is placed
   (format.md §9.1), bad files are quarantined, and no raw iCloud version picker can ever reach a
   vault file.
7. **About 1,800 lines of app code and about 1,800 lines of app tests are deleted** (the in-place
   iCloud reading machinery and the WebDAV fetcher that rides on it). Coordination, conflict versions
   and the presenter move into the folder transport.
8. **Migration happens on first launch**: an iCloud vault is copied to the device (it is downloaded
   first) and the iCloud folder becomes its sync target. A WebDAV copy is completed and switched to
   two-way. Nothing is deleted anywhere.
9. **Ten PR-sized phases.** The first two are invisible refactors that can ship in the next TestFlight
   build. Two-way WebDAV in the app (P5) is the first user-visible step, and iCloud device-first (P6)
   follows.

## 1. Where we are (verified in code and docs)

| Kind | Where the vault lives | How other devices' changes arrive | Offline |
| --- | --- | --- | --- |
| iCloud Drive | in iCloud Drive itself (a user-picked folder) | iCloud's daemon. The app reads in place with `NSFileCoordinator`, maps `.icloud` placeholders and dataless files (`CloudScan`), polls download states (`ProgressiveLoad`, `AppModel+Cloud`), fetches blobs on demand (`CloudBlobs`) and merges iCloud's conflict versions of mutable files (`CloudConflicts`) | partial: evicted files and unrequested blobs are missing |
| WebDAV (app) | a local copy, `Application Support/Sempere/WebDAV/<location>/` | none, except **Download Again**. Runs are push-only (`WebDAVSyncOptions.pushOnly`). The copy starts partial and is filled by `WebDAVFetcher`, which poses as iCloud (`CloudVault.Hooks`) | full once it is filled |
| WebDAV (CLI) | any local folder | two-way `sempere sync webdav` (`WebDAVSync`, 1,125 lines, plus about 4,700 lines in 22 more files) | full |
| Local / other provider | a picked folder | none, or the provider's daemon (the coordinated path in `StorageLocation`) | depends on the provider |

The engine's two-way rules (docs/io.md "WebDAV sync") already cover write-once files (a three-way table
against `SyncState.files`), compaction deletes (`CompactionPlanner`, retention 0, the remote held to
§5.3 and §5.8.4), blob GC (§8.1.6 rules 1 to 4, `blobRetention`), `vault.json` and the journal (hash
three-way, `incomingManifestProblem`, `incomingJournalProblem`, in-flight journals), `settings.age`
(per-key merge), notebook records, published summaries for the web viewer, quarantine, run bounds,
resumable blobs, concurrency, skip-unchanged, deep listings and partial copies. The format has no
last-writer-wins file that matters (§1.3), so two-way sync is mostly a union.

The engine **does not** sync `inbox/` (quick capture), `keys/` (passphrase-wrapped identities) or
`summaries/<device>.sealed`. It also does not propagate a recipient change, which rewrites files under
`notes/` in place (docs/io.md "Limits").

### 1.1 Where the app treats WebDAV as second-class today, and how each goes away

| Today | Where | Goes away by | Phase |
| --- | --- | --- | --- |
| Runs are push-only. Other devices' notes, settings and key changes never reach the copy | `AppModel+WebDAV`, `WebDAVSession`, `pushOnly`, `keepServerChanges` | a two-way `SyncSession` for every target | P5 |
| "Download Again" is the only way to receive other devices' changes | `WebDAVDownload.swift`, the status bar menu | scheduled two-way runs. "Download Again" becomes **Repair** for every target (§8) | P5, P9 |
| Key changes are refused (`requireLocalKeyChanges`: 4 call sites in `AppModel+Keys`, 1 in `AppModel+KeyChangeResume`, `WebDAVVaultError.keyChangesUnavailable`) | the app | the rewrap-replace rule (§5.2), then the refusal is deleted | P4, P10 |
| Shared settings never arrive locally (a push-only run uploads merges and writes nothing locally) | docs/settings-sync.md "WebDAV sync" | a two-way merge writes both sides | P5 |
| A server `vault.json` or journal changed elsewhere is only reported ("device list changed elsewhere") | `keepServerChanges` | taken under the existing two-way checks | P5 |
| No background tasks or scheduled refresh | docs/io.md "When it pushes" | one scheduler for every target (§4) | P8 |
| Quick-capture inbox files never leave the device that recorded them | the engine ignores `inbox/` | inbox sync (§5.3) | P4 |
| A second device cannot unlock with a passphrase-wrapped key from the vault | `keys/` is not synced | `keys/` sync (§5.1) | P4 |
| Filling depends on the iCloud machinery (`WebDAVFetcher` as `CloudVault.Hooks`, iCloud texts relabeled through `CloudSource`) | `WebDAVFetcher` (411 lines) | deleted. Join fills the vault through the engine | P5, P7 |
| A separate status bar (`WebDAVStatusBar`) and a separate join flow (connect, then a partial copy) | `WebDAVViews` | one status model and one join flow (§8) | P5, P9 |
| "The intended use is one writing device per server folder" | docs/io.md | multi-writer as the design goal, with stress tests over 2 to 4 devices | P2, P5 |
| Recent entries are special-cased (no bookmark, `VaultLibrary.resolve` throws for them) | `VaultLibrary`, `RecentVault.webdav` | every vault is a local entry with targets | P6 |

iCloud has its own gaps that the same change closes. Received files are not checked before they are
placed (iCloud's daemon places them). A conflicted mutable file can reach a raw version picker (the
1.0.0 (1) P0 note loss started there). Offline access is partial.

## 2. Target model

```
Device
 └─ Vault (complete local folder, the only thing the app reads and writes)
     ├─ target: iCloud Drive  (folder transport + iCloud hooks)   ┐ zero, one, or
     ├─ target: WebDAV        (WebDAV transport)                  ┘ (later) several
     └─ per-target sync state, quarantine, staging (outside the vault)
```

- **Local folder.** On iOS and iPadOS:
  `<App Group container>/Library/Application Support/Sempere/Vaults/<vaultId>/<name>.sempere`. The
  App Group (`group.io.github.anthonytw.sempere`, already entitled for the widgets) lets quick capture
  and widgets write to the inbox without the app. Data Protection is `completeUntilFirstUserAuthentication`
  (files are age-encrypted anyway). On the Mac the default is the same; a user-picked local folder is
  also allowed (for the CLI, Time Machine and scripts). A folder inside iCloud Drive or
  `~/Library/CloudStorage` is refused as a *vault* (`StorageLocation` classifies it), with an offer to
  add it as a *target* instead.
- **Always complete.** After a join finishes, the local vault holds every revision and every blob.
  Partial-copy markers (format.md §1.2) exist only while a join is in progress (§8.2).
- **Targets.** `none`, `iCloud Drive folder`, `WebDAV collection`, or `other folder`. The engine and
  state are per target, so several targets per vault work by construction (this device then bridges
  them). The first release offers one target per vault. See open question Q2.
- **Format.** No on-disk format change. format.md gains normative text for the rewrap-replace rule
  (§5.2) and inbox deletes (§5.3). §3.3's "do them from one device while others are idle" stays as
  advice, not a requirement.

## 3. One sync engine, many transports

### 3.1 Targets and portability

| Target | Contents | Linux | Network |
| --- | --- | --- | --- |
| `SempereSync` (new) | the engine (today's `WebDAVSync*`, `BlobSync`, `NotebooksSync`, `SettingsSync`, `SummariesSync`, `PartialSync`, `LocalCopy`, `Prefetch`, `Preupload`, `TransferPool`, `Quarantine`, `SyncState`, `SyncReport`, `SyncProgress`, `TreeListing`, `NoteStamps`, `LocalFS`, `PushOnlySync`), the `SyncRemote` protocol, `FolderRemote`, `MemoryRemote`, and `SyncSchedule` (today's `PushSchedule`, generalized) | yes | none |
| `SempereSync` + `#if canImport(Darwin)` | `UbiquitousFolderHooks`: `NSFileCoordinator`, `startDownloadingUbiquitousItem`, `ubiquitousItemIsUploaded`, `NSFileVersion` conflict versions, `NSFilePresenter`. Foundation only, which `check-portability.sh` allows. The app and the macOS CLI share it | compiled out | none |
| `SempereWebDAV` | `WebDAVClient`, `URLSessionTransport`, `WebDAVRemote: SyncRemote` | yes | the only network target, as today |
| `Apps/` | `SyncSession` (scheduling, status, BGTasks), target setup UI, the Keychain, certificate pinning | — | — |

The CLI keeps `sempere sync webdav` (same flags; `--push-only` stays for the web viewer mirror) and adds
`sempere sync folder PATH --vault V [--identity F] [--json]`. On macOS, `sync folder` uses the
ubiquitous hooks when PATH is ubiquitous, so a Mac can bridge iCloud and WebDAV with two cron lines.

### 3.2 The `SyncRemote` protocol

The engine already uses only ten client calls (`list`, `listTree`, `stat`, `get`, `put` from data or
from a file with a `PutCondition`, ranged `download`, `move` without overwrite, `mkcol`, `delete` with
`ifMatch`, `createBase`). The protocol is those calls with transport-neutral names, plus capabilities
and availability:

```swift
public protocol SyncRemote: Sendable {
    var capabilities: RemoteCapabilities { get }   // strong stamps, range reads, deep listing,
                                                   // folder stamps change on child write, temp+move needed
    func list(_ path: [String]) throws -> [RemoteEntry]?          // nil: not there
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree?
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, stamp: String?)
    func download(_ path: [String], to: URL, resumeFrom: Int, ifStamp: String?, ...) throws -> DownloadResult
    func write(_ path: [String], _ body: RemoteBody, _ condition: PutCondition) throws -> Bool  // false: precondition lost
    func moveNoOverwrite(_ from: [String], to: [String]) throws -> Bool
    func makeCollection(_ path: [String]) throws
    func delete(_ path: [String], ifStamp: String?) throws -> Bool
    // Evictable stores only (default: always .available, nothing to do):
    func availability(_ path: [String]) -> RemoteAvailability    // .available / .remoteOnly / .downloading / .failed(String)
    func requestDownload(_ paths: [[String]]) throws
    func conflictVersions(_ path: [String]) -> [RemoteVersion]    // NSFileVersion for iCloud; [] elsewhere
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws
    func changes() -> AsyncStream<RemoteChange>?                  // presenter or metadata hints; nil: poll only
}
```

`RemoteEntry` gains an `availability` field. `WebDAVError` is split into `SyncError` (engine) and
`WebDAVError` (transport). `WebDAVSyncOptions` and `WebDAVSyncProgress` become `SyncOptions` and
`SyncProgress`, with WebDAV-only knobs (segment size, `publishForWebViewer`) moved to the adapter.

| Capability | WebDAV | Folder (plain) | Folder (iCloud or another provider) | Memory |
| --- | --- | --- | --- | --- |
| create only | `If-None-Match: *` PUT; blobs to a temporary name, then `MOVE`, `Overwrite: F` | temporary file + `link(2)` (rename fallback) | the same, inside a coordinated write | yes |
| conditional replace | `If-Match` (strong ETag) | stamp compare, then atomic rename, under a lock file | the same, coordinated. iCloud may still fork the file, which shows up as conflict versions | yes |
| stamp | ETag, else Last-Modified | size + mtime (ns) + file id | the same | counter |
| range and resume | `Range` / `If-Range` | file offset | once local | yes |
| folder change hint (`skipUnchangedNotes`) | collection ETag where seen to work | directory mtime | presenter reports | — |
| deep listing | `Depth: infinity` where seen to work | `FileManager` enumerator | enumerator, mapping `.<name>.icloud` to `<name>` | yes |
| availability | always | always | per file, from `ubiquitousItemDownloadingStatus` and dataless checks | scriptable |

**Eviction tolerance** (the one engine change the folder transport needs). A listed file that is
`.remoteOnly` or `.downloading` *exists*: the engine requests it, skips it this run ("arriving",
counted in progress), and never treats it as dropped, missing or extraneous. Only a file absent from
the listing is absent. This is the same promise partial copies already make (format.md §1.2 rule 4),
applied to the remote side. A note whose remote revisions are not all available is settled in a later
run, as an incomplete note is today. "Not listed yet" folders (iCloud lists a folder before its
children) get the existing `cloudUnlistedTimeout` treatment inside the transport.

**Uploads to iCloud** finish when the file is in the iCloud folder. iCloud's daemon then uploads it
on its own schedule, even while the app is suspended. The status shows "Uploading to iCloud: n" from
`ubiquitousItemIsUploaded` of files written in recent runs, so "Synced" is honest.

**Change notification.** The folder transport runs an `NSFilePresenter` on the target's `notes/` and
root (the existing `NotesFolderPresenter`, moved). `NSMetadataQuery` is not used: its ubiquitous
scopes need the iCloud entitlement, which personal-team builds lack, and they do not cover a folder
the user picked outside the app's container (see `CloudChanges.swift`). WebDAV has no push channel,
so it is polled (§4).

**Later providers.** S3-compatible stores (conditional writes with `If-None-Match`, ETags, ranged
GETs) and Dropbox (`rev`-conditional uploads, `list_folder/continue` cursors) map onto the same
protocol. Each would be a new adapter in a network target, with no engine change. Not designed here.

### 3.3 The local side

The engine already writes local files with the vault's atomic helpers (`LocalFS`: write-once with
`link(2)`, mutable files replaced with an fsync). In the app the local vault is open while the engine
runs. Write-once names never collide, so only mutable files need care:

- One in-process `VaultFileLock` per vault serializes the engine's replacement of `vault.json`,
  `rewrap-journal.json` and `settings.age` with the app's own writes of them. A cross-process `flock`
  on `<state dir>/.lock` covers the CLI and the app on one Mac folder.
- The engine's report adds `changedNotes: Set<UUID>`, `manifestChanged`, `settingsChanged`,
  `inboxChanged` and `notebooksChanged`. The model reacts to each: `noteFoldersChanged(ids)`,
  `reloadManifest()` (as after a local key change), `SettingsSyncBridge.reload()`, inbox adoption, and
  the notebook tree.

## 4. Triggers and scheduling

One `SyncSession` per open vault and target runs `SyncSchedule`, which is today's `WebDAVPushSchedule`
logic made two-way. At most one run per target at a time. A trigger during a run schedules exactly
one more run.

| Trigger | iCloud folder | WebDAV |
| --- | --- | --- |
| local write (`NoteWriter` delta or blob, capture, settings) | run 2 s after the last write (local disk I/O only) | 10 s after the last write (as today) |
| presenter report | run at once for the named notes (a scoped run) | — |
| unlock, open, app becomes active | run | run |
| periodic while open | every 60 s (presenter reports cover the rest) | 30 s while something is arriving, then 5 min, doubling to 15 min while idle; reset by any change |
| network becomes reachable (`NWPathMonitor` in the app) | — (iCloud handles the network) | run, cancel the backoff |
| app goes to the background | run under `beginBackgroundTask` (as `finishBackgroundSync` today) | the same |
| `BGAppRefreshTask` (15 min or more) | one scoped run (§4.1) | one run with `maxDuration` 25 s |
| `BGProcessingTask` (network, power optional) | a full run (validation) | a full run, including blobs |
| "Sync Now" | run, clear the backoff | run, clear the backoff |
| failure | 30 s backoff, doubling to 15 min (as today) | the same |

**Scoped runs.** A run can be limited to named notes (presenter reports, a note the user opens) and
to the root files. This is the engine's existing `fetch` scope, generalized to two-way. A full run
still happens at least every `fullListingInterval`.

**Arrivals.** Files are placed by the engine, then `changedNotes` is passed to `noteFoldersChanged`,
then the existing change-driven reconcile reads only those notes (`IndexDiff`), then an open editor
whose folder now has unknown revision names merges them (`AppModel+RemoteMerge`, unchanged). The
list update path (`queueListUpdate`) and "Updated from another device" are unchanged.

### 4.1 Locked runs (background and before unlock)

A scheduled task often finds the vault locked (the key is behind Face ID). The engine can already run
locked (structure checks only; no deletions; mutable files reported as conflicts). For the app:

- **Uploads** run locked: everything local that the remote lacks. Write-once uploads need no key.
- **Downloads** go to a **staging folder** (`<state dir>/incoming/`, outside the vault) after the
  locked structure check (§9.1, second bullet). At the next unlock they are checked fully and placed
  (a local operation, fast), or quarantined. The vault folder therefore never holds a file that was
  not checked under the key. (Today a locked CLI pull places well-formed forgeries; the app would not.)
- Mutable files, deletions and blob GC wait for an unlocked run.

## 5. Conflicts and safety

### 5.1 Every file

| File | Rule (existing unless marked new) |
| --- | --- |
| revisions `notes/<id>/*.age` | union by the three-way table. Never overwritten, except under rewrap-replace (§5.2, new). Checked before placing; quarantined on failure |
| blobs `notes/<id>/att/*` | the same, blobs before their note's revisions, resumable. GC deletes under §8.1.6 rules 1 to 4 with `blobRetention` |
| compaction and thinning deletes | propagated only when `CompactionPlanner` explains them from snapshots the other side holds, never a checkpoint or anchor (§5.3, §5.8.4). An emptied remote deletes nothing locally |
| `vault.json` | hash three-way. Label-only differences are the same vault (the server's label wins). A changed device list is taken only unlocked and verified (`incomingManifestProblem`). Both sides changed: a conflict copy plus a report, nothing replaced |
| `rewrap-journal.json` | the existing two-way rules: never replace an unfinished local journal; refused or planted journals are rejected; in-flight journals are held for a day |
| `settings.age` | merged per key when unlocked; a newer-reader copy is mirrored byte for byte; locked: conflict |
| `notebooks/*.notebook.age` | write-once union |
| `keys/<name>.key.age` (**new** in the engine) | write-once by name (§1.3: a rewrite holds the same key). A missing file is copied; a different file under the same name is reported, never replaced. Checked as an age file whose name parses; never trusted to unlock without the passphrase |
| `inbox/*.capture.age`, `*.transcript.age` (**new**) | union, plus adoption-aware deletes (§5.3) |
| `summaries/<device>.sealed` (**new**) | each device uploads its own file (replace with a stamp condition) and downloads the others'. A hint only, never used to write. Lets a joining device list notes before they arrive (§8.2) |
| `sempere-summaries.sealed`, `sempere-index.json` | rewritten for the web viewer as today (WebDAV only, opt-in) |
| conflict versions (iCloud `NSFileVersion`) | the folder transport presents them as extra candidates for the same path. The engine merges them by the rules above (the existing `CloudConflicts` logic, moved), then resolves and removes them. No version picker ever appears |

### 5.2 Key changes across devices (new: rewrap-replace)

A recipient change rewrites revisions and blobs in place under their names, and renames blobs on
removal (§3.3, §8.1.5). Today sync cannot propagate this. New rule, for the engine only, with the
vault unlocked:

1. `vault.json` and `rewrap-journal.json` propagate first, under the existing checks. A device that
   takes a new `vault.json` with `rewrapPending` treats the change as accepted (format.md §3.3.1).
2. A write-once path (a revision, a blob, or an inbox file, which `Vault.rewrapInbox` also rewrites)
   whose bytes differ between the two sides (local hash differs from the recorded
   hash, or the remote stamp differs from the recorded stamp, with both present) is a **rewrap
   candidate**. Both copies are opened. If both verify (tag under the current secret or the journal's
   previous one) and their bodies are equal (the same `gzip(JSON)` bytes for a revision, the same
   content hash for a blob), the copy that is **current** (§3.3.1 step 3: one stanza per current
   recipient, tag under the current secret) is kept, and the other side's copy is replaced with a
   stamp condition (a local atomic replace, or a remote `If-Match`). If both are current, the remote
   copy is kept, so all devices converge.
3. Anything else is never replaced: different bodies, a copy that fails verification (it is
   quarantined), or a locked vault (the file is listed as "waiting for unlock"). This means a hostile
   server cannot downgrade a file to an older recipient set, cannot put back a removed recipient's
   stanza, and cannot swap content.
4. Blob renames on removal are a union of the new names. The old names are collected by GC once no
   journal exists on either side (rule 2 of §8.1.6 already blocks this until then).
5. A device that wrote revisions under the old list while the change ran (it was offline) resumes the
   rewrap for its own files when it unlocks (`resumeRewrap`, as today), and rule 2 propagates them.

Consequences: the app offers key changes for every vault, synced or not, and `requireLocalKeyChanges`
is deleted. A key change waits until the local vault is complete (§1.2 rule 3) and until the target's
last run finished cleanly, so the device starts from the current list (format.md §3.3 already stops a
change when `vault.json` changed underneath). Two devices changing keys at once leave a `vault.json`
conflict, which is reported and never merged; the second change is refused until the first one has
arrived. Limitation, stated in the UI: a removed device's key can still open old copies kept in
server backups or iCloud version history. Rotation protects what is written afterwards.

### 5.3 Quick capture `inbox/`

- Captures are written to the local vault's `inbox/` through the App Group path. This works offline
  and with the vault locked. The `CaptureQueue` remains only for a vault that is read-only for this
  build (format.md §7.3).
- The engine syncs `inbox/` as a union, so any device that unlocks can adopt (§11.3). Adoption IDs are
  derived from the capture id, so concurrent adoptions write the same note.
- **Deletes propagate only when adoption explains them** (new). An inbox file absent on one side and
  recorded as synced is deleted on the other side only if the derived note exists there with the
  recording (for a capture), or with its transcript (for a transcript). This is checked unlocked;
  otherwise the file is copied back. A server can therefore not make devices drop an unadopted
  capture.

### 5.4 Deletions and thinning

Deleting a note is a revision (soft delete, Recently Deleted), so it is a union. Physical deletes come
only from compaction, thinning and blob GC, and they propagate by the existing explain-or-restore
rules. "Thin everything except checkpoints" on one device reaches the others as explained deletes,
which closes the 1.0.0 (1) "old versions remained" report for synced vaults. A run never deletes on a
side where the note is incomplete or a listed file is unavailable (§3.2).

### 5.5 Hostile or broken remotes (format.md §9)

Every guarantee the WebDAV engine has applies to every transport, because they live in the engine:
received files are checked before they are placed (§9.1) and quarantined otherwise; names are
validated (no path escape); bodies, listings and runs are bounded (`SyncLimits`); a remote
`vault.json` of another vault aborts the run; device lists are checked against the trust record. New
for iCloud: none of this applied before, because iCloud's daemon wrote into the vault directly. A
corrupted or planted file in the iCloud folder now stays out of the vault.

### 5.6 Devices on different targets

- A vault synced through iCloud on device A and through WebDAV on device B, with no device holding
  both, is **two islands**. Nothing is lost (each target is a valid vault) and nothing crosses. Merging
  later is safe: add the second target to any device (or run `sempere sync folder` and
  `sempere sync webdav` on one Mac), and the union rules converge.
- A device with both targets **bridges** them. Each run is a union against the local vault, so data
  flows iCloud → local → WebDAV. Two bridges are fine. Compaction deletes cross a bridge only when
  explained on each hop.
- The UI shows, per vault, which devices (by name from the trust record, and by the device ids in
  revision names) have written through this target recently. This makes islands visible without a
  format change (see Q8).

## 6. Migration (pre-1.0: no backward compatibility kept)

| Starting point | First launch of the new build |
| --- | --- |
| iCloud vault (a recent entry with a bookmark in iCloud Drive) | A sheet: "Sempere now keeps a full copy of each vault on this device and syncs it with iCloud Drive. Your notes stay in iCloud Drive too." The app then (1) creates the local folder; (2) runs a **join** from the iCloud folder as the target (§8.2), which downloads every file with a progress bar; the vault opens, locked, as soon as the root files are local, and notes fill in; (3) replaces the recent entry with a local entry that has an iCloud target. Nothing in iCloud Drive is moved or deleted. Offline at that moment: the vault opens from what iCloud already holds locally, marked "Finishing download". |
| WebDAV copy (`Application Support/Sempere/WebDAV/<location>/`) | Moved to the new vault location (a rename within the container; the App Group needs a copy) and kept as a partial copy if it is one. Its location becomes a WebDAV target with the same sync state, and its next run is two-way. The Keychain item and pin are kept. |
| Local folder (Mac) or other provider | A local folder stays where it is. A folder in another provider becomes an "other folder" target, as with iCloud. |
| Capture profiles | Rebound to the new vault path at the first unlock (`refreshCaptureProfile`). A queued capture is flushed into the local inbox. |

Old builds on other devices keep working against the same iCloud folder or server during the
transition, because the target is a normal vault. The `.sempere` package-era vaults still go through
`vault merge-copy`.

## 7. What gets deleted or moved

| Code (lines today) | Fate |
| --- | --- |
| `CloudScan` (322), `ProgressiveLoad` (140), `CloudBlobs` (62), `AppModel+CloudDownload` (64), `CloudProgressView` (21), most of `AppModel+Cloud` (395) and `CloudVault` (245: `requireLocal`, `downloadBlob`, `Hooks`) | **deleted**. The app reads a complete local folder |
| `WebDAVFetcher` (411), `WebDAVDownload` (106) | **deleted** (filling is the engine's join; Download Again becomes Repair) |
| about 110 call sites of `isCloudVault`, `cloudHooks` and `coordinated:` in 20 files (export, history, thinning, attachments, inbox, search, backup, notebooks, recordings) | **simplified**: one local path |
| `CloudConflicts` (184), `AppModel+CloudConflicts` (43), `CloudChanges` (129), the coordination part of `CloudVault` | **moved** into the folder transport and `UbiquitousFolderHooks` |
| `AppModel+WebDAV` (404), `WebDAVSession` (199), `AppModel+Background` (107), `BackgroundSync` (123) | **reworked** into a target-neutral `SyncSession` and scheduler |
| `StorageLocation` (57) | **kept**, to refuse provider folders as vaults |
| `AppModel+PublishedSummaries` (84) | **kept** (per-device summaries), no longer iCloud-gated |
| Library: `PushOnlySync`, `PartialSync`, `LocalCopy` | **kept** in `SempereSync`. Push-only serves the web viewer; partial is used during joins |
| App tests: `ProgressiveLoadTests` (580), `CloudSyncTests` (589), `AttachmentCloudTests` (228), `CloudTests` (137), `WebDAVPartial*` (305) | **replaced** by engine and transport tests in the package (Linux-run) |
| docs/io.md "iCloud Drive", "Background sync", "Other Files providers", "WebDAV vaults in the app" (about 500 lines) | **rewritten** as "Sync targets" (about 200 lines) |

The estimate: about **−1,800 lines** of app code and about **−1,800 lines** of app tests. On the other
side, about +600 lines of app code (`SyncSession`, setup and status UI) and about +2,000 lines in the
package (protocol, folder and memory transports, new file kinds, rewrap-replace, and their tests).
Most of the logic that remains becomes Linux-tested.

## 8. UI

### 8.1 Vault setup

- **New Vault**: a name, then "Sync with: None / iCloud Drive / WebDAV server…". iCloud creates
  `<name>.sempere` in `iCloud Drive/Sempere/` by default; "Choose Folder…" picks another place.
  WebDAV uses the existing connect sheet (URL, user, password, Test Connection, certificate pin).
- **Vault ▸ Sync…** (any vault): add, change or remove the target. Adding one to a vault that already
  has content uploads it: the first run is a union, so this is also how two islands are merged.
  Removing a target never deletes anything remote.
- **Join an existing vault** (welcome screen, "Open Synced Vault…"): iCloud Drive (pick the
  `.sempere` folder) or WebDAV (connect, then pick from the vault list). These are one flow and one
  progress UI.

### 8.2 Join

1. A metadata pull (the engine's `.metadata`, generalized): the root files, `keys/`, `notebooks/`,
   `summaries/`, and the note list. The vault becomes a partial copy (format.md §1.2) and opens
   locked within a few requests.
2. Unlock: Face ID transfer, a remembered key, or a passphrase key from `keys/`.
3. Fill: the engine's two-way run completes the copy (notes the user opens first, then the rest, then
   blobs), and the list shows pending notes from the published summaries, with a spinner and the bar
   "Downloading n of m notes". When it finishes, the marker goes away and the vault is offline-ready.
4. While partial: key changes, compaction, Recognize All and backup wait (as today). Edits to
   complete notes and new notes work, and quick capture works.

### 8.3 Status (one model for every target)

The bar under the list and a toolbar glyph show one of these states:

| State | Text |
| --- | --- |
| synced | "Synced with iCloud Drive · 2 min ago" / "Synced with nas.example · 2 min ago" |
| syncing | "Syncing: ↑ 3 ↓ 12 notes" with progress (and "Uploading to iCloud: n" from `isUploaded`) |
| offline | "Offline. Changes are kept on this device and sync when you are back online." Not an error |
| waiting | "Waiting for unlock: 4 changes from other devices" (staged, §4.1) |
| problem | what happened and what to do: wrong password, certificate changed, server full, quarantined files (n), device-list conflict, another vault at that address, iCloud signed out or full |

The menu has Sync Now, Show Details (the last report: uploaded, downloaded, skipped, quarantined,
conflicts), Target Settings…, and Repair….

### 8.4 Storage and repair

- **Settings ▸ Storage**: per vault, the size on this device (notes, attachments, caches), the size of
  the iCloud folder copy if it is local, and the sync state with quarantine. "Clear Caches" covers
  only caches.
- **Repair…** (replaces "Download Again" and works for every target): (1) a full run with
  `--checksum`-style verification of every local file, re-downloading what fails; (2) "Retry
  quarantined files"; (3) "Reset sync state" (the next run is a first sync: a union that deletes
  nothing). A rebuild from scratch is a join into a new folder, then a merge of the old one
  (`Vault.mergeCopy`), never a blind replace.
- **Remove from This Device** warns with the count of changes that no target has confirmed (today's
  `unconfirmedChanges`, generalized).

## 9. Testing strategy

| Layer | What | Runs |
| --- | --- | --- |
| Protocol conformance | one `SyncRemoteConformanceTests` suite (create-only races, conditional replace, stamps, listings, range resume, missing paths, hostile names) run against `MemoryRemote`, `MockServer` WebDAV, `FolderRemote`, and an **`EvictingFolderRemote`** (a Linux port of FakeCloud: placeholders, dataless files, delayed delivery, conflict versions) | `swift test`, Linux and macOS |
| Engine over every transport | today's `SyncTests`, `BlobSyncTests`, `JournalSyncTests`, `RecipientsSyncTests`, `RemoteDeletionTests`, `PartialCopyTests` and others, parameterized over Memory, WebDAV-mock and Evicting-folder | `swift test` |
| New rules | rewrap-replace (add, remove, replace; interrupted; a concurrent offline writer; a hostile downgrade, swap or stanza re-add; locked), inbox deletes (adopted, unadopted, concurrent adoption), `keys/` and `summaries/` | `swift test`, plus fuzz targets for the new readers |
| Multi-device | `TwoDeviceStressTests` generalized to N devices and **mixed targets** (A on iCloud, B on WebDAV, C bridging), random interleavings of edits, compaction, captures, key changes, eviction and faults. Invariants: no write-once file is ever lost; every device converges to the same reconstruction; nothing unverified is placed | `swift test` (few seeds), `scripts/sync-stress.sh` (60+ seeds) |
| Real server | wsgidav plus `dav-fault-proxy.py` (resets, 5xx, stalls, drips), `SyncFaultProxyTests`, `SyncTimingTests`, now including two-way app-shaped runs (scoped, locked staging) | CI `webdav` job, sync-stress |
| App | `SyncSession` scheduling with a fake clock and a `MemoryRemote`; migration of a FakeCloud iCloud vault and of a partial WebDAV copy; RemoteMerge fed by engine reports; `TwoDeviceVaultTests` on two local vaults through one remote | Mac Catalyst unit tests (PR gate) |
| macOS iCloud hooks | `UbiquitousFolderHooks` against a real non-ubiquitous folder (coordination is a no-op) and the conflict-version API with `NSFileVersion` on a local file | `swift test` on macOS |

**Device checks that remain for the owner** (everything else is automated):

1. iPad and iPhone (and Mac) on one iCloud vault: create on one, join on another, edit on both in
   airplane mode, reconnect, and confirm the notes converge with no version prompt.
2. In the Files app, "Remove Download" on the iCloud folder copy while the app syncs.
3. Background: lock the iPad with changes pending on the iPhone, and check after 30 minutes or more
   (BGAppRefresh timing cannot be simulated).
4. A Lock Screen quick capture on device A, adopted on device B.
5. Migration of the owner's real iCloud vault (after a backup).
6. WebDAV on cellular against the owner's server, and the same two-device test as check 1.

## 10. Phased plan

Sizes: S < 300 changed lines, M 300 to 1,000, L > 1,000 (moved lines count once).

| # | PR | Size | Depends on | Risk | TestFlight |
| --- | --- | --- | --- | --- | --- |
| P1 | `SempereSync` target: move the engine; `SyncRemote` protocol; `WebDAVRemote` adapter; renames; the CLI is unchanged and every existing test passes unmodified (except names) | L (mostly moves) | — | a large diff hides a behavior change. Mitigation: the move commit and the rename commit are separate; no logic changes | **next build** (invisible) |
| P2 | `MemoryRemote`, the conformance suite, and engine suites parameterized over transports; N-device stress | M | P1 | none to users | **next build** (tests only) |
| P3 | `FolderRemote` + `EvictingFolderRemote` + eviction tolerance in the engine + `UbiquitousFolderHooks` + `sempere sync folder` (CLI, docs/cli.md, CLITests) | L | P2 | eviction rules wrong means a run sees absent files. Mitigation: availability is checked before every judgment; property tests | next build (CLI only) |
| P4 | Engine parity: `keys/`, `inbox/` with adoption-aware deletes, `summaries/<device>`, rewrap-replace (§5.2); format.md text; security-review pass | L | P1 | security-sensitive. Mitigation: hostile-server tests and a review before merge | after review |
| P5 | App: local vault store + `SyncSession` + two-way WebDAV (drop push-only, Download Again → Sync Now; the status model; arrivals → RemoteMerge; settings merge locally); migrate WebDAV copies | L | P1, P4 (inbox, keys) | first two-way writes into an open vault. Mitigation: `VaultFileLock`, existing two-device app tests | candidate for the build after next, the first user-visible step |
| P6 | App: iCloud as a folder target; new-vault and join flows; migrate iCloud vaults; App Group vault root; quick capture to the local inbox | L | P3, P5 | migration of real data. Mitigation: never delete remote; owner check 5 | — |
| P7 | Delete the in-place iCloud machinery, `WebDAVFetcher` and their tests; rewrite docs/io.md and the iCloud and WebDAV gotchas in CLAUDE.md | M (mostly deletions) | P6 | removing a path still used. Mitigation: the compiler, plus `isCloudVault` reaching zero | — |
| P8 | Scheduling: BGAppRefresh and BGProcessing for every target, reachability, locked staging (§4.1) | M | P5 | iOS timing. Mitigation: owner check 3 | — |
| P9 | UI: status details, Storage, Repair, target settings, the devices-per-target view, multiple targets (if Q2 says yes) | M | P5, P6 | — | — |
| P10 | Key changes for synced vaults in the app (delete `requireLocalKeyChanges`); two-device key-change app tests | S to M | P4, P5 | a rewrap racing a sync. Mitigation: the rewrap holds the sync lock; resume is idempotent | — |

Critical path: P1 → P2 → P4 → P5 → P6 → P7. P3 can run alongside P4. P8, P9 and P10 can run in
parallel after P5. Roughly 8 to 10 author sessions.

## 11. Open questions (with recommendations)

| # | Question | Recommendation |
| --- | --- | --- |
| Q1 | Where do vaults live on iOS: hidden (App Group, Application Support) or visible in Files ("On My iPad")? | **Hidden, in the App Group**: quick capture and widgets can write there, and Files cannot rename or break it. Backups and the sync targets are the user-visible copies |
| Q2 | More than one target per vault? | **Yes in the engine and the model from day one; one per vault in the UI at first.** Add "also sync with…" in P9 once the mixed-target stress tests are green. It is the clean answer to islands |
| Q3 | Download every attachment, always? | **Yes.** Offline is a requirement and vaults are small. Revisit only if someone asks for "keep large attachments only in the cloud" |
| Q4 | Locked background runs: place structurally-checked files, or stage them until unlock? | **Stage** (§4.1). The vault never holds an unverified file, and placing at unlock is a fast local step |
| Q5 | Migrate iCloud vaults automatically, or ask first? | **Automatically, with an explanatory sheet**, since nothing remote changes. Offer "Keep in iCloud only" only if a test user objects (it would be the old code path, which we delete) |
| Q6 | Mac: allow a user-chosen local folder? | **Yes** (CLI, Time Machine, scripts), but refuse iCloud Drive and `CloudStorage` folders as vaults and offer to add them as targets |
| Q7 | Evict the iCloud folder copy after upload to save space (`evictUbiquitousItem` once `isUploaded`)? | **No for now.** Measure first: the double copy is small, and iOS evicts under storage pressure anyway |
| Q8 | Record the targets each device uses in the vault (a new optional file), so islands can be detected exactly? | **No format change now.** Show the devices seen through each target, derived from revision names. Reconsider after P9 |
| Q9 | Keep a push-only (read-only mirror) target kind for the web viewer? | **Keep it in the CLI** (`--push-only`). In the app, add a "Publish read-only copy" target only when the web viewer ships to users |
| Q10 | Allow key changes while other devices are offline? | **Yes.** They catch up through rewrap-replace and resume their own late files. The app warns "Change keys on one device at a time" and refuses while this device's last sync is not clean |
| Q11 | Treat "other folder" providers (Proton Drive) as supported? | **Offer them under "Other Folder…", labeled as not tested by the project**, because the folder transport covers them at no extra cost. Promise only iCloud Drive and WebDAV |

## 12. Alternatives considered

- **Keep iCloud in place and make WebDAV two-way only.** This keeps partial offline access,
  placeholder handling in every feature (110 call sites), and an iCloud-only path with weaker checks.
  It also keeps two sync models to test. Rejected.
- **CloudKit (private database with `CKAsset`)** as the iCloud transport. It has real change tokens and
  no file-level conflicts, but it needs the iCloud entitlement and a schema, and it gives up a vault
  that the stock CLI, Finder and backups can read. It could be another adapter later. Not now.
- **A File Provider extension** that presents local vaults to Files. It solves a different problem
  (visibility), not sync. Not now.
- **Partial copies by default** (fetch on demand, like iCloud today). This contradicts "offline access
  is 100% necessary". Partial copies are kept only as the transient state of a join.
