# Device-first vaults with two-way sync (design)

Status: **design approved by the owner on 2026-10-19** (answers in §11). Nothing is implemented yet. The
key-change review (§6) is a gate that must pass before P4 and P10 land.

Owner's decision (2026-10-19):

> Sync both ways. Probably switching the structure to be device first with iCloud or WebDAV sync is
> the way to go. [...] offline access is 100% necessary.

> [Keeping everything on device] takes up so little space, I can't imagine wanting to store it online
> and lose access to note taking whenever your device is in airplane mode.

> If you didn't support two-way sync on WebDAV, that means you can't sync devices across a different
> provider other than iCloud. I don't want people locked into iCloud. WebDAV should have first-class
> support.

> If I open a directory mounted in iCloud or wherever, that should be fine. If I also back up to
> iCloud, so what? No restrictions on where you place your vault.

## 0. Summary

1. **The app reads and writes only a complete working copy** of each vault, kept in the app's own
   container (hidden, on iOS, iPadOS and the Mac). Everything works offline, always. There are no
   coordination calls, placeholders or download waits anywhere in the app's read and write paths.
2. **A vault can be placed anywhere.** A folder the user picks or creates (in iCloud Drive, another
   File Provider, a USB drive, a network share, or `~/Documents`) is a **sync target** of the working
   copy. This is how placement works with no restrictions: the provider-specific hardening lives in the
   folder transport, not in the app.
3. **Targets are provider-neutral, and a vault can have several.** Kinds: folder (iCloud Drive, other
   providers, plain folders) and WebDAV. Every target gets the same two-way sync, status, scheduling,
   conflict handling and join flow. "Multiple backups is great": several targets per vault are
   supported from day one, and a device with two targets bridges them.
4. **One engine.** The two-way engine that `SempereWebDAV` already has moves to a new network-free
   target, `SempereSync`, and runs over an extensible `SyncRemote` protocol. WebDAV becomes one
   adapter. A folder adapter (Linux-portable, with Darwin hooks for coordination, downloads and
   conflict versions) serves iCloud Drive and every other folder. The CLI gets `sempere sync folder`.
   Dropbox, S3 or Proton can be added later as adapters (§3.4).
5. **The engine gains what parity needs**: sync of `inbox/`, `keys/` and `summaries/<device>.sealed`;
   **rewrap-replace**, so key changes propagate through any target; and a **key-change claim**, a
   device-local **secret keyring** and **late-file handling**, so that no key-change failure loses data
   (§6).
6. **Arrivals reuse what exists**: the engine reports changed notes into `noteFoldersChanged`, which
   drives reconcile and then `AppModel+RemoteMerge`.
7. **iCloud and other providers get the WebDAV guarantees**: every received file is checked before it is
   placed (format.md §9.1), bad files are quarantined, and no version picker ever reaches a vault file.
8. **No migration.** There is no version 1 yet; the owner re-imports. An existing vault folder in iCloud
   Drive simply opens through the normal "Open Folder…" join.
9. **Removal, revised honestly.** The app loses about 1,400 lines outright. About 900 lines of today's
   iCloud hardening are **kept and moved** into the folder transport, because placed vaults need them
   (§7). App tests: about 1,000 lines are deleted and about 800 are ported to Linux-run transport tests.
10. **Eleven PR-sized phases.** P1 to P3 are invisible or CLI-only and can ship in the next TestFlight
    build. P4a is the key-change safety gate. P5 (two-way WebDAV in the app) is the first user-visible
    step.

## 1. Where we are (verified in code and docs)

| Kind | Where the vault lives | How other devices' changes arrive | Offline |
| --- | --- | --- | --- |
| iCloud Drive | in iCloud Drive itself (a user-picked folder) | iCloud's daemon. The app reads in place with `NSFileCoordinator`, maps `.icloud` placeholders and dataless files (`CloudScan`), polls download states (`ProgressiveLoad`, `AppModel+Cloud`), fetches blobs on demand (`CloudBlobs`) and merges iCloud's conflict versions of mutable files (`CloudConflicts`) | partial: evicted files and unrequested blobs are missing |
| WebDAV (app) | a local copy, `Application Support/Sempere/WebDAV/<location>/` | none, except **Download Again**. Runs are push-only (`WebDAVSyncOptions.pushOnly`). The copy starts partial and is filled by `WebDAVFetcher`, which poses as iCloud (`CloudVault.Hooks`) | full once it is filled |
| WebDAV (CLI) | any local folder | two-way `sempere sync webdav` (`WebDAVSync`, 1,125 lines, plus about 4,700 lines in 22 more files) | full |
| Local / other provider | a picked folder | none, or the provider's daemon (the coordinated path in `StorageLocation`) | depends on the provider |

The engine's two-way rules (docs/io.md "WebDAV sync") already cover:
- write-once files (three-way against `SyncState.files`);
- compaction deletes (`CompactionPlanner`, with the remote held to §5.3 and §5.8.4);
- blob GC (§8.1.6 rules 1 to 4, `blobRetention`);
- `vault.json` and the journal (`incomingManifestProblem`, `incomingJournalProblem`, in-flight journals);
- `settings.age` (per-key merge) and notebook records;
- quarantine, run bounds and resumable blobs;
- concurrency, skip-unchanged, deep listings and partial copies.

The engine **does not** sync `inbox/`, `keys/` or `summaries/<device>.sealed`, and it does not propagate
a recipient change (docs/io.md "Limits").

### 1.1 Where the app treats WebDAV as second-class today, and how each goes away

| Today | Where | Goes away by | Phase |
| --- | --- | --- | --- |
| Runs are push-only. Other devices' notes, settings and key changes never reach the copy | `AppModel+WebDAV`, `WebDAVSession`, `pushOnly`, `keepServerChanges` | a two-way `SyncSession` for every target | P5 |
| "Download Again" is the only way to receive | `WebDAVDownload.swift`, the status bar menu | scheduled two-way runs. "Download Again" becomes **Repair** for every target (§8.4) | P5, P9 |
| Key changes are refused (`requireLocalKeyChanges`: 4 call sites in `AppModel+Keys`, 1 in `AppModel+KeyChangeResume`) | the app | §5.2 and §6, then the refusal is deleted | P4a, P4, P10 |
| Shared settings never arrive locally | docs/settings-sync.md "WebDAV sync" | a two-way merge | P5 |
| A server `vault.json` or journal changed elsewhere is only reported | `keepServerChanges` | taken under the existing two-way checks | P5 |
| No background tasks | docs/io.md "When it pushes" | one scheduler for every target (§4) | P8 |
| Inbox files never leave the device that recorded them | the engine ignores `inbox/` | inbox sync (§5.3) | P4 |
| A second device cannot unlock with a passphrase key from the vault | `keys/` is not synced | `keys/` sync | P4 |
| Filling rides the iCloud machinery | `WebDAVFetcher` (411 lines) | deleted: the engine's join | P5, P7 |
| A separate status bar and a separate join flow | `WebDAVViews` | one status model and one join flow (§8) | P5, P9 |
| "One writing device per server folder" | docs/io.md | multi-writer as the goal, with N-device stress tests | P2, P5 |
| Recent entries are special-cased (no bookmark) | `VaultLibrary`, `RecentVault.webdav` | every vault is a working copy with targets | P6 |

iCloud has its own gaps that the same change closes. Received files are not checked before they are
placed. A conflicted mutable file can reach a raw version picker (the 1.0.0 (1) P0 note loss started
there). Offline access is partial.

## 2. Target model

```
Device
 └─ Vault working copy  (complete, in the app's container; the only folder the app reads and writes)
     ├─ target: folder  "iCloud Drive/Notes.sempere"   (folder transport + ubiquitous hooks)
     ├─ target: WebDAV  "https://nas.example/dav/Notes" (WebDAV transport)
     ├─ target: folder  "/Volumes/USB/Notes.sempere"    (folder transport, plain)
     └─ per-target sync state, quarantine, staging       (outside the vault)
```

- **Working copy.** It lives at
  `<App Group container>/Library/Application Support/Sempere/Vaults/<vaultId>/<name>.sempere`, hidden,
  on every platform. The App Group (`group.io.github.anthonytw.sempere`, already entitled) lets
  quick capture and widgets write to the inbox. Data Protection is
  `completeUntilFirstUserAuthentication` (the files are age-encrypted anyway).
- **Placing a vault** means adding a folder target. "New Vault in Folder…", "Open Folder…" and "Add
  Sync Target…" all create one. There are no restrictions on where the folder is. Even a plain local
  folder on the Mac goes through a target rather than being opened in place, for two reasons. The
  app then has one read and write path. And folders that other tools sync (Dropbox's classic folder,
  Syncthing, an SMB share) cannot surprise the open vault.
- **Always complete.** After a join finishes, the working copy holds every revision and every blob.
  Partial-copy markers (format.md §1.2) exist only while a join is in progress (§8.2).
- **The cost** is two copies on a device whose target is a local folder, or an iCloud folder that
  stays downloaded. The owner accepts this ("takes up so little space").
- **CLI interop on the Mac.** The CLI keeps working directly on the placed folder. The app sees CLI
  writes through the folder target within one run (FSEvents or the presenter wakes it; §4).
- **Format.** There is no on-disk format change. format.md gains normative text for rewrap-replace
  (§5.2), inbox deletes (§5.3) and late files (§6). §3.3's "do them from one device while others are
  idle" stays as advice, and the claim (§6.1) enforces it where targets allow.

## 3. One sync engine, many transports

### 3.1 Targets and portability

| Target | Contents | Linux | Network |
| --- | --- | --- | --- |
| `SempereSync` (new) | the engine (today's `WebDAVSync*`, `BlobSync`, `NotebooksSync`, `SettingsSync`, `SummariesSync`, `PartialSync`, `LocalCopy`, `Prefetch`, `Preupload`, `TransferPool`, `Quarantine`, `SyncState`, `SyncReport`, `SyncProgress`, `TreeListing`, `NoteStamps`, `LocalFS`, `PushOnlySync`), `SyncRemote`, `FolderRemote` (with the placeholder, dataless and unlisted logic moved from `CloudScan` and `ProgressiveLoad`), `MemoryRemote`, `SyncSchedule` | yes | none |
| `SempereSync`, `#if canImport(Darwin)` | `UbiquitousFolderHooks`: `NSFileCoordinator`, `startDownloadingUbiquitousItem`, `ubiquitousItemIsUploaded`, `NSFileVersion` conflict versions (moved from `CloudConflicts`), `NSFilePresenter` (moved from `CloudChanges`), and the provider classification (moved from `StorageLocation`). Foundation only, which `check-portability.sh` allows. The app and the macOS CLI share it | compiled out | none |
| `SempereWebDAV` | `WebDAVClient`, `URLSessionTransport`, `WebDAVRemote: SyncRemote` | yes | the only network target today |
| `Apps/` | `SyncSession` (scheduling, status, BGTasks), the target registry and setup UI, the Keychain, certificate pinning | — | — |

The CLI keeps `sempere sync webdav` (same flags; `--push-only` stays for the web viewer mirror) and adds
`sempere sync folder PATH --vault V [--identity F] [--json]`. On macOS it uses the ubiquitous hooks
when PATH is in a provider.

### 3.2 The `SyncRemote` protocol

The engine already uses only ten client calls. The protocol is those calls with transport-neutral
names, plus capabilities, availability and change hints:

```swift
public protocol SyncRemote: Sendable {
    var capabilities: RemoteCapabilities { get }
    func list(_ path: [String]) throws -> [RemoteEntry]?          // nil: not there; entries carry availability
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree?   // nil: not supported
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, stamp: String?)
    func download(_ path: [String], to: URL, resumeFrom: Int, ifStamp: String?, ...) throws -> DownloadResult
    func write(_ path: [String], _ body: RemoteBody, _ condition: PutCondition) throws -> Bool  // false: precondition lost
    func moveNoOverwrite(_ from: [String], to: [String]) throws -> Bool
    func makeCollection(_ path: [String]) throws
    func delete(_ path: [String], ifStamp: String?) throws -> Bool
    // Lazy stores only (the defaults: everything available, nothing to do, no conflict versions):
    func requestDownload(_ paths: [[String]]) throws
    func conflictVersions(_ path: [String]) -> [RemoteVersion]
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws
    func changes() -> AsyncStream<RemoteChange>?                  // nil: poll only
}
```

| Capability | WebDAV | Folder (plain) | Folder (provider: iCloud and others) | Memory |
| --- | --- | --- | --- | --- |
| create only | `If-None-Match: *`; blobs: temporary name then `MOVE`, `Overwrite: F` | temporary file + `link(2)` (rename fallback) | the same, inside a coordinated write | yes |
| conditional replace | `If-Match` (strong ETag) | stamp compare + atomic rename under a lock file | the same, coordinated; a fork shows up as conflict versions | yes |
| stamp | ETag, else Last-Modified | size + mtime (ns) + file id | the same | counter |
| range and resume | `Range` / `If-Range` | file offset | once local | yes |
| change hint | collection ETag (where seen to work) | FSEvents (macOS), directory mtime | presenter reports | stream |
| deep listing | `Depth: infinity` (where seen to work) | enumerator | enumerator, mapping `.<name>.icloud` to `<name>` | yes |
| availability | always | always | per file: downloading status and dataless check | scriptable |

### 3.3 Placed vaults: the vault folder is itself in iCloud or another provider

Because the app never opens the placed folder directly, correctness for provider folders is the folder
transport's job. The transport keeps every piece of today's hardening, moved out of the app:

| Hazard in a provider folder | Today (app) | After (folder transport) |
| --- | --- | --- |
| evicted files: `.<name>.icloud` stand-ins, or dataless files under their real names | `CloudScan` maps them; `CloudVault.requireLocal` refuses to read them | `list` maps them to real names with `availability = .remoteOnly`. The engine treats them as existing but not readable: it requests them, skips them this run, and never treats them as dropped, missing or extraneous. Only a file absent from the listing is absent (format.md §1.2 rule 4, applied to the remote side) |
| a note folder listed before its files | pending for `cloudUnlistedTimeout`, then set aside (`emptyNoteFolders`) | the same rule in the transport. Such a folder is "arriving" and is never read as an empty note or a dropped note |
| an `att/`-only folder (an import in progress elsewhere) | not a note (`ProgressiveLoad.Pass.orphans`) | the same: never judged, never synced as a note until a revision appears |
| downloads of many files | windows of 64 notes, the user's note first, stall detection at 90 s (`ProgressiveLoad`, `cloudCheckLimit`) | `requestDownload` takes windows; the engine asks in the order the session gives (the notes the user opens first). A stall becomes a target problem, not an alert |
| other processes writing (iCloud's daemon, Finder, the CLI) | coordinated reads and writes (`CloudVault.coordinatedRead` / `coordinatedWrite`, `NoteWriter(coordinated:)`) | every transport read and write is coordinated when `UbiquitousFolderHooks` classify the folder as a provider (`StorageLocation`'s rules). Plain folders use the lock file |
| conflict versions of mutable files (`vault.json`, journal, `settings.age`, summaries, `keys/`) and of the vault folder itself (a package-era conflict) | `CloudConflicts` merges by format.md §1.3 and resolves before each pass | `conflictVersions` hands each version to the engine as an extra candidate for that path. The engine merges by the §5.1 rules: settings per key; `vault.json` by label equality, else a reported conflict; write-once files as a union through `Vault.mergeCopy`. Then `resolveConflicts` removes them. No version picker ever reaches the user |
| changes from other devices | `NotesFolderPresenter` wakes the loop | `changes()` from the same presenter, scoped runs (§4) |
| upload completion | not shown | "Uploading to iCloud: n" from `ubiquitousItemIsUploaded` |
| a provider that lists nothing until Files has shown the folder, or a stale bookmark | `VaultLocator`, `VaultBookmark` refresh | the target holds the bookmark. A dead one is a target problem ("choose the folder again"); the working copy is unaffected |
| hostile or corrupted files placed by the provider | none: readers skip bad files | §9.1 checks before placing, then quarantine (§5.5) |

Placed vaults also add two cases that today's code does not have:

- **A tool other than Sempere edits the placed folder** (the CLI, another device's old build, a restore).
  To the engine this is just another writer, so its files are unioned and checked.
- **The same folder is also reached by a different route.** For example, iCloud Drive on one Mac and
  the same files over WebDAV from a NAS that mirrors that Drive folder. Each route is one target, and
  the union rules converge. Stamps are per target, so a file that changes under a second route is seen
  as changed, never assumed unchanged.

### 3.4 Extension points for later providers

Other providers go under "Other Folder…" for now. The protocol stays open so that a first-class
integration (Dropbox API, S3, Proton) can be added later without touching the engine:

| Extension point | What a new provider supplies |
| --- | --- |
| `SyncRemote` | the calls above. Create-only and conditional replace map to S3 `If-None-Match` and `If-Match`, and to Dropbox `mode: add` and `update: rev` |
| `RemoteCapabilities` | flags the engine already branches on: strong stamps, ranged reads, deep listing, folder stamps that change on a child write, atomic create (otherwise temporary name then move, or create then verify), maximum object size |
| `RemoteAvailability` + `requestDownload` | for stores that hold files lazily (a Proton or Dropbox app's File Provider; not needed by API adapters) |
| `changes()` | a push channel: Dropbox longpoll cursors, S3 event notifications. `nil` means poll |
| `SyncTargetKind` (app registry) | id, display name, icon, setup view, `makeRemote(config, credentials)`, a status vocabulary ("Synced with Dropbox") |
| `SyncCredentialStore` | Keychain items keyed by target id (today's WebDAV password store, generalized); OAuth tokens for API providers |
| CLI | `sempere sync <kind> …` subcommands that share the option set (`SyncOptions`) |
| Policy | each network adapter is its own target (e.g. `SempereS3`). Adding one means updating the "network only in…" rule in CLAUDE.md, `check-portability.sh`, `release-check.sh`'s `NETWORK_ALLOWED`, and the privacy policy |

## 4. Triggers and scheduling

One `SyncSession` per vault and target runs `SyncSchedule` (today's `WebDAVPushSchedule`, made two-way).
At most one run per target at a time. A trigger during a run schedules one more run. Runs for several
targets of one vault take turns on the vault's sync lock.

| Trigger | Folder target | WebDAV |
| --- | --- | --- |
| local write (`NoteWriter` delta or blob, capture, settings) | 2 s after the last write | 10 s after the last write |
| change hint (presenter, FSEvents) | a scoped run at once for the named notes | — |
| unlock, open, app becomes active | run | run |
| periodic while open | 60 s | 30 s while something is arriving, then 5 min, doubling to 15 min while idle |
| network reachable (`NWPathMonitor`) | — | run, cancel the backoff |
| app goes to the background | run under `beginBackgroundTask` | the same |
| `BGAppRefreshTask` | a scoped run (locked: §4.1) | one run, `maxDuration` 25 s |
| `BGProcessingTask` | a full run, re-requesting evicted files | a full run including blobs |
| "Sync Now" / failure | run at once / 30 s backoff, doubling to 15 min | the same |

**Arrivals.** The engine places files. Its report (`changedNotes`, `manifestChanged`, `settingsChanged`,
`inboxChanged`, `notebooksChanged`) drives `noteFoldersChanged` and then reconcile (`IndexDiff` reads
only those notes). An open editor merges the new revisions (`AppModel+RemoteMerge`, unchanged). The
other flags drive manifest reload, `SettingsSyncBridge`, inbox adoption and the notebook tree.

**Local side.** An in-process `VaultFileLock` serializes the engine's replacements of mutable files with
the app's own writes. A cross-process `flock` covers the CLI on the same working copy.

### 4.1 Locked runs

- **Uploads** run locked (write-once uploads need no key).
- **Downloads** go to a staging folder (`<state dir>/incoming/`) after the structure check (§9.1). At the
  next unlock they are checked fully and placed, or quarantined, so the working copy never holds an
  unverified file.
- Mutable files, deletions, blob GC and rewrap-replace wait for an unlocked run.

## 5. Conflicts and safety

### 5.1 Every file

| File | Rule (existing unless marked new) |
| --- | --- |
| revisions `notes/<id>/*.age` | union, three-way; never overwritten except by rewrap-replace (§5.2); checked before placing |
| blobs `notes/<id>/att/*` | the same, before their note's revisions, resumable; GC under §8.1.6 with `blobRetention` |
| compaction and thinning deletes | propagated only when explained by snapshots the other side holds; an emptied remote deletes nothing |
| `vault.json` | hash three-way; label-only differences are the same vault; a changed list is taken only unlocked and verified; both sides changed: conflict copy + report |
| `rewrap-journal.json` | existing two-way rules, plus §6 (claims, and never uploading a journal this device refuses) |
| `settings.age` | per-key merge (unlocked); locked: conflict |
| `notebooks/*.notebook.age` | write-once union; rewrap-replace applies |
| `keys/<name>.key.age` (**new**) | write-once by name; a differing file under the same name is reported, never replaced |
| `inbox/*` (**new**) | union, adoption-aware deletes (§5.3); rewrap-replace applies |
| `summaries/<device>.sealed` (**new**) | each device writes only its own; the others' are downloaded as hints |
| `sempere-summaries.sealed`, `sempere-index.json` | web viewer mirror files, as today |
| provider conflict versions | merged as extra candidates by the rules above, then resolved (§3.3) |

### 5.2 Rewrap-replace (new)

A recipient change rewrites files in place under their names, and on removal renames blobs (format.md
§3.3, §8.1.5). The engine may replace a write-once file only under all of these conditions:

1. The vault is unlocked, and **both sides hold the same `vault.json`** (the same hash at the start of
   the run). If they differ, no file is replaced in either direction this run. This prevents one
   device's stale list from pushing old copies over newer ones.
2. The path's bytes differ, and both copies decrypt and verify (tag under the current secret, under the
   journal's previous secret, or under a secret in this device's keyring, §6.3).
3. Their bodies are equal: the same `gzip(JSON)` for a revision, notebook record or `settings.age`; the
   same content hash for a blob; the same audio or transcript for an inbox file.
4. Exactly one copy is **current** under that shared `vault.json` (one stanza per current recipient,
   tag under the current secret). That copy wins. If both are current, the copy with the smaller
   SHA-256 wins, so devices and bridges converge whichever target they meet first.

Anything else is never replaced: the file is quarantined if it fails verification, and otherwise
reported. Old blob names are collected by GC only after no journal exists on either side and the
retention has passed.

### 5.3 Quick capture `inbox/`

- Captures are written to the working copy's `inbox/` through the App Group path (offline, locked).
- The engine syncs `inbox/` as a union, so any device that unlocks can adopt (adoption IDs are derived
  from the capture id).
- **New:** an inbox file deleted on one side is deleted on the other only when adoption explains it.
  The derived note must exist with the recording (for a capture) or with its transcript (for a
  transcript), checked unlocked. Otherwise the file is copied back.

### 5.4 Deletions and thinning

Deleting a note is a revision, so it is a union. Physical deletes (compaction, thinning, blob GC)
propagate only by the explain-or-restore rules. No deletion is ever judged for a note that is
incomplete or has an unavailable listed file.

### 5.5 Hostile or broken remotes (format.md §9)

Every guarantee lives in the engine and so applies to every target:
- §9.1 checks before placing, then quarantine;
- name validation;
- `SyncLimits`;
- the vault-id check;
- trust records.

This is new for iCloud and other providers, whose daemons used to write into the vault directly.

### 5.6 Devices on different targets

- Devices that share no target are **islands**: nothing is lost and nothing crosses. Adding a common
  target to any device, or bridging with the CLI, converges them by union.
- A device with two targets **bridges** them. Compaction deletes cross a bridge only when explained on
  each hop. Rewrap-replace converges across bridges because of the tie-break in §5.2.
- The UI lists the devices seen through each target, from the trust record and from the device ids in
  revision names (no format change).

## 6. Key changes across devices: failure review (gate for P4 and P10)

The owner's requirement: no key-change scenario may end in data loss if some part fails. This section
enumerates the steps, then every failure, the invariant that keeps data recoverable, and the
fault-injection test that proves it. **P4 (rewrap-replace) and P10 (key changes in the app for synced
vaults) do not merge until every test in §6.4 exists and passes, including the 3-device property
run.** That work is phase P4a.

### 6.1 Steps

On device A, which makes the change (format.md §3.3.1, plus the new steps C0, C1 and C5):

| Step | What happens |
| --- | --- |
| C0 | Preconditions. The working copy is complete; the list verifies; no journal is pending; every target synced cleanly within the last minute; A's keyring stores the current secret. |
| C1 | **Claim** (new). Write `rewrap-journal.json` create-only (`If-None-Match: *`, or `link(2)`) to **every** target. If any target already has a journal (another device's change in flight), abort, delete A's own claims (with `If-Match`) and report. If a target is unreachable, refuse; the user can override for one target, and is warned. |
| K1 | Write the journal locally. It holds the outgoing secret, encrypted to the new set, when the secret rotates. |
| K2 | Write `vault.json` locally (new list, secret, tags, `secretLink`, `rewrapPending`). |
| K3 | Rewrap every file locally (revisions, blobs, inbox, `settings.age`, notebook records, summaries). On a removal, blobs move to new names and the old names go only when K4 completes. |
| K4 | Clear `rewrapPending` locally and delete the local journal (only when every file is complete). |
| C5 | **Propagate** (new ordering). Per target: (a) the journal (already there from C1) and the K2 `vault.json` with `rewrapPending`; (b) the rewritten files by rewrap-replace and the new blob names; (c) the K4 `vault.json`; (d) delete the remote journal with `If-Match`, only when A's sync state shows every file on that target is the current copy. Old blob names go later, by GC. |

On device B, which receives the change:

| Step | What happens |
| --- | --- |
| R1 | Take the journal (held as in flight while unbound) and `vault.json` (verified by tag and `secretLink`). B's keyring stores B's **old** secret before its `vault.json` is replaced. |
| R2 | Take the rewritten files by rewrap-replace (only while both sides hold the same `vault.json`). |
| R3 | B's own files that never reached a target (late files written under the old list) are rewrapped by B from its keyring, then uploaded. |
| R4 | The journal disappears from the target; B refuses it from then on (existing rule). |

### 6.2 Failures, outcomes and invariants

| # | Failure | Outcome | Invariant that keeps data recoverable | Test (§6.4) |
| --- | --- | --- | --- | --- |
| F1 | A crashes after C1, before K1 | Unbound journal claims sit on the targets. Other devices hold them as in flight for a day, then reject them. A deletes its own claims at the next launch, since a claim with no local change is stale | no file has changed; claims never bind anything | `crashAfterClaim` |
| F2 | A crashes between K1 and K2 | The local journal is unbound and refused at open. **The engine never uploads a journal this device refuses** (new) | every file is still under the old list and the old secret | `crashAfterJournal` |
| F3 | A crashes during K3 | The change resumes at open (`resumeRewrap`). Files not yet rewritten verify under the journal's previous secret | the journal is deleted only after every file is complete (existing); the keyring keeps the old secret too | `crashDuringRewrap(n)` for n across revisions, blobs and inbox |
| F4 | Replace, where the old key is the only one able to read pending files, and the old key is lost mid-change | the pending files are unreadable until the old key returns | **the app refuses to forget, delete or overwrite the outgoing identity (Keychain, remembered keys) while any target or the working copy has a pending replace**; the CLI already warns | `replaceKeepsOldKey` (app) |
| F5 | A goes offline after C5(a) (`vault.json` uploaded, files not yet) | B takes the new `vault.json` and journal. B's files are not current and the remote copies are not current either, so nothing is replaced, and everything still verifies under the journal's previous secret. B may finish the rewrap itself (add or remove); both-current copies converge by the tie-break | the remote journal stays until a run confirms every remote file current (C5(d)) | `partialUploadThenOtherDeviceFinishes` |
| F6 | A uploads the files before `vault.json` (a bug, or a transport that reorders) | B holds the old list and sees remote copies current under a list it does not hold. Under rule 1, nothing is replaced because the `vault.json` versions differ once A's arrives; before that, B judges remote copies "not current" and does **not** push its own over them, since replacement needs exactly one current copy under a shared list | rule 1 plus rule 4: a stale list never overwrites | `filesBeforeManifest` |
| F7 | Two devices change keys at once, and one target is unreachable at C1 | Without the override, the change is refused (C1). With it, both changes complete locally. Then `vault.json` conflicts on the shared target: a conflict copy plus a report, and **no file is replaced** (rule 1). The user picks "Keep the other change" on one device, which rewraps that device's files from its own list to the other list using its keyring (it knows both secrets), then redoes its change | a device never discards a secret it has written files under until those files are verified current under the adopted list | `concurrentChangesWithOverride` |
| F8 | A stale device returns after the change finished (journal gone everywhere) | R1: B's keyring keeps its old secret before taking the new `vault.json` (B can confirm the rotation through `secretLink`). R3: B rewraps its own late files and uploads them. Others' stale copies on B are replaced by the current remote copies | late files are never dropped: they are rewrapped by their writer, or held (F9) | `staleDeviceReturns(days:)` |
| F9 | Files under the old secret that A never saw arrive on a target after the change finished (written by C, offline) | If the receiving device's keyring verifies them **and** they arrive within the late-file window (7 days after the change, from the receiver's first sighting of the new `vault.json`), they are rewrapped and uploaded. Later ones are **quarantined as late files**, never deleted, and shown in "Changes from before a key change" with "Adopt" and "Export". The window exists because a removed device also knows the old secret | old-secret files are never placed silently after the window, and never deleted | `lateFilesWithinWindow`, `lateFilesAfterWindowQuarantined` |
| F10 | A removed device keeps writing | It cannot tag under the new secret, so its new files either fail verification (quarantined at once) or carry the old secret's tag (late files: F9's window and quarantine). Its own working copy keeps its notes, and its UI says "This device was removed. N changes were not uploaded", with Export | a removed device's local data stays readable to it; it never reaches others silently | `removedDeviceWrites` |
| F11 | A partial upload of one file (a cut connection) | WebDAV uploads go to a temporary name and then `MOVE` (blobs), or a conditional PUT (revisions). Folder writes use a temporary file then rename. A receiver either sees the old file or the complete new one | atomic replace on every transport; rewrap-replace re-checks both copies every run | `cutDuringReplace` (fault proxy and Memory faults) |
| F12 | A receiver crashes while replacing a local file | `LocalFS` atomic replace leaves the old or the new complete file. The candidate is judged again next run | the same | `crashDuringLocalReplace` |
| F13 | The vault is locked on a receiver | rewrap-replace waits; staged downloads wait; the status says "Waiting for unlock" | nothing is replaced without the key | `lockedReceiver` |
| F14 | Blob rename on removal is interrupted | Both names exist. Lookups try the current name, then the previous one (existing). The old name is collected only by GC after the journal is gone on both sides and the retention has passed | a blob is never deleted while any copy of its note could still reference the old name | `blobRenameInterrupted` |
| F15 | A hostile or broken target serves an older copy (an old recipient set, or a removed stanza re-added) | not current under the shared list, so it is never taken; a copy that fails verification is quarantined | rule 4; §9.1 | `hostileDowngrade`, `hostileStanzaReadd` |
| F16 | A provider forks `vault.json` (iCloud conflict versions) during a change | the transport presents both versions; the engine treats it as a `vault.json` conflict (F7) unless the versions differ only in label | no blind pick, ever | `providerForksManifest` (EvictingFolderRemote) |

### 6.3 New mechanisms this requires

- **Secret keyring.** Device-local, outside the vault, and sealed with a key in the Keychain (in the
  CLI's state directory, sealed to the device key). It holds every vault secret this device has used
  for that vault, with the date each was replaced. It is used only to verify and rewrap files under an
  older secret (R3, F7, F8, F9). It never leaves the device and is never synced. It holds secrets the
  device already knew, so it reveals nothing new if the device is compromised.
- **Claims** (C1), with create-only writes on every target.
- **No upload of refused journals** (F2), and **remote journal delete only when the target is
  confirmed current** (C5(d)).
- **The late-file window** and the quarantine view (F9).
- **The app guard against forgetting the outgoing identity** while a replace is pending (F4).

### 6.4 Fault injection (the P4a gate)

- **`RewrapFaults`** (core, test-only injection): it fails or crashes (simulated by abandoning the
  `Vault` mid-operation) after C1, after K1, after K2, after file n of K3, and before K4. The engine
  gets the same hooks for C5(a) to C5(d) and for local replaces.
- **`KeyChangeScenarioTests`**: one test per row F1 to F16 above, over `MemoryRemote` and the
  WebDAV mock. F11 also runs against wsgidav behind `dav-fault-proxy.py` (rules that cut the `MOVE` and
  PUT bodies). F16 runs over `EvictingFolderRemote`.
- **`KeyChangeInterleavingTests`** (property test, seeded, in `scripts/sync-stress.sh`): 3 devices and
  2 targets. Random edits; adds, removes and replaces on random devices; crashes at random fault
  points; devices going offline and coming back after random delays; locked runs; and a hostile target
  that sometimes serves old copies. Invariants checked after every step and at quiescence:
  - **I1, no loss.** Every revision body ever written by a device that is still listed is readable
    (decrypts and verifies) on some device or target, in the vault or in the late-file quarantine.
  - **I2, convergence.** With faults off and every device synced twice, all working copies and
    targets hold the same `vault.json`, and the same bytes for every write-once path.
  - **I3, body integrity.** No path ever holds two different bodies over time.
  - **I4, revocation.** After convergence and GC retention, no file in any working copy or target
    (excluding provider version history and the quarantine) has a stanza for a removed recipient.
  - **I5, liveness.** Every pending journal is finished or reported within a bounded number of runs.
- **Gate:** P4 and P10 merge only when these suites are green, the sync-stress run passes with 60 or
  more seeds, and a security review of §5.2 and §6 has signed off.

## 7. What gets deleted, what stays (revised for placed vaults)

Placed vaults need today's provider hardening, so much of it **stays**, moved from the app into the
folder transport. What goes is every **consumer** of in-place reading in the app.

| Code (lines today) | Fate |
| --- | --- |
| `CloudScan` (322): placeholder and dataless mapping, file states | **stays**, moved into `FolderRemote` (Linux part) and `UbiquitousFolderHooks` |
| `ProgressiveLoad` (140): the download-window and stall logic (about 70 lines) | **stays**, in `FolderRemote.requestDownload` |
| `ProgressiveLoad`: pending rows and list passes (about 70 lines) | **deleted** (the join lists pending notes from published summaries, §8.2) |
| `CloudVault` (245): coordination (about 95 lines) | **stays**, in the hooks |
| `CloudVault`: `requireLocal`, `downloadBlob`, `Hooks` (about 150 lines) | **deleted** |
| `CloudConflicts` (184) + `AppModel+CloudConflicts` (43) | **stay**, as the transport's conflict-version source plus engine merge rules |
| `CloudChanges` (129) | **stays**, as `changes()` |
| `StorageLocation` (57) | **stays**, to classify which folders need coordination and hooks (not to refuse anything) |
| `AppModel+Cloud` (395) | **deleted** except for about 60 lines of presenter wiring, which go to `SyncSession` |
| `CloudBlobs` (62), `AppModel+CloudDownload` (64), `CloudProgressView` (21) | **deleted** |
| `WebDAVFetcher` (411), `WebDAVDownload` (106) | **deleted** |
| about 110 `isCloudVault` / `cloudHooks` / `coordinated:` sites in 20 files (about 250 lines) | **simplified** to one local path |
| `AppModel+WebDAV` (404), `WebDAVSession` (199), `AppModel+Background` (107), `BackgroundSync` (123) | **reworked** into `SyncSession` and the scheduler |
| `AppModel+PublishedSummaries` (84) | **kept**, no longer iCloud-gated |
| Library: `PushOnlySync`, `PartialSync`, `LocalCopy` | **kept** (web viewer mirror; joins) |
| App tests: `ProgressiveLoadTests` (580), `CloudSyncTests` (589), `AttachmentCloudTests` (228), `CloudTests` (137), `CloudConflictTests` (202), `WebDAVPartial*` (305) | about 1,000 lines **deleted** (list, pending-row and on-demand blob tests); about 800 lines **ported** to `FolderRemote` / `EvictingFolderRemote` tests on Linux (placeholders, dataless files, unlisted folders, orphans, conflict versions) |
| docs/io.md "iCloud Drive", "Background sync", "Other Files providers", "WebDAV vaults in the app" (about 500 lines) | **rewritten** as "Sync targets" and "Folder targets in providers" (about 300 lines) |

**Estimate:**
- App code: about **−1,400 lines deleted**, about **900 lines moved** into `SempereSync`, and about
  **+500 lines new** (`SyncSession`, the target registry, setup and status UI).
- App tests: about **−1,000 lines deleted** and about **800 lines ported**.
- Package: about **+2,500 lines**, covering the protocol, the folder and memory transports, new file
  kinds, rewrap-replace, the §6 mechanisms, and their tests.

The earlier draft said −1,800 lines of app code. That assumed provider folders would be refused, which
they are not.

## 8. UI

### 8.1 Vault setup and targets

- **New Vault**: a name, then "Keep a copy in: None / iCloud Drive / A Folder… / WebDAV Server…".
  iCloud Drive defaults to `iCloud Drive/Sempere/<name>.sempere`.
- **Open Folder…** and **Connect to WebDAV…** (welcome screen): join a vault that already exists (§8.2).
  An existing iCloud vault from earlier builds opens this way; there is no migration.
- **Vault ▸ Sync Targets…**: lists every target with its status. "Add Target…" accepts any number of
  targets; adding one to a vault with content uploads it (a union, which is also how islands merge).
  "Remove" never deletes anything remote.

### 8.2 Join

1. A metadata pull: root files, `keys/`, `notebooks/`, `summaries/` and the note list. The working copy
   is a partial copy (format.md §1.2) and opens locked within a few requests.
2. Unlock: Face ID transfer, a remembered key, or a passphrase key from `keys/`.
3. Fill: notes the user opens first, then the rest, then every attachment. The list shows pending
   notes from the published summaries. When the fill finishes, the vault is offline-ready.
4. While the copy is partial, key changes, compaction, Recognize All and backup wait. Edits to complete
   notes, new notes and quick capture work.

### 8.3 Status

| State | Text |
| --- | --- |
| synced | "Synced · iCloud Drive, nas.example · 2 min ago" |
| syncing | "Syncing: ↑ 3 ↓ 12 notes" (and "Uploading to iCloud: n") |
| offline | "Offline. Changes are kept on this device and sync when you are back online." Not an error |
| waiting | "Waiting for unlock: 4 changes from other devices" |
| problem | per target: wrong password, certificate changed, folder not found ("choose it again"), server or iCloud full, quarantined files (n), late files from before a key change (n), device-list conflict |

The menu has Sync Now, Show Details (per target: the last report), Sync Targets…, and Repair….

### 8.4 Storage and repair

- **Settings ▸ Storage**: per vault, the working copy's size (notes, attachments, caches), each folder
  target's size if it is local, and the sync state and quarantine.
- **Repair…** (every target): verify every local file and fetch again what fails; retry quarantined
  files; review late files (Adopt or Export); reset a target's sync state (the next run is a union that
  deletes nothing).
- **Remove from This Device**: warns with the count of changes no target has confirmed.

## 9. Testing strategy

| Layer | What | Runs |
| --- | --- | --- |
| Protocol conformance | `SyncRemoteConformanceTests`: create-only races, conditional replace, stamps, listings, resume, missing paths, hostile names. Runs over `MemoryRemote`, the WebDAV mock, `FolderRemote`, and `EvictingFolderRemote` (a Linux port of FakeCloud: placeholders, dataless files, unlisted folders, delayed delivery, conflict versions) | `swift test`, Linux and macOS |
| Engine over every transport | today's sync suites, parameterized over Memory, the WebDAV mock and Evicting-folder | `swift test` |
| Placed vaults | the §3.3 hazards over `EvictingFolderRemote`: eviction mid-run, unlisted folders, orphans, forks of every mutable file, a foreign writer, stale bookmarks | `swift test` |
| New rules | rewrap-replace, inbox deletes, `keys/` and `summaries/`, and fuzz targets for the new readers | `swift test` |
| Key changes | §6.4: `RewrapFaults`, `KeyChangeScenarioTests` (F1 to F16), `KeyChangeInterleavingTests` | `swift test`, sync-stress |
| Multi-device | `TwoDeviceStressTests` generalized to N devices and mixed and multiple targets (bridges included) | `swift test`, `scripts/sync-stress.sh` |
| Real server | wsgidav + `dav-fault-proxy.py`, `SyncFaultProxyTests`, `SyncTimingTests`, two-way app-shaped runs | CI `webdav` job, sync-stress |
| App | `SyncSession` scheduling with a fake clock; RemoteMerge fed by engine reports; two working copies through one remote; the outgoing-identity guard (F4) | Mac Catalyst unit tests (PR gate) |
| Darwin hooks | `UbiquitousFolderHooks` on a local folder (coordination as a no-op) and `NSFileVersion` on a local file | `swift test` on macOS |

**Device checks that remain for the owner:**
1. Two or three devices on a vault placed in iCloud Drive: edit in airplane mode, reconnect, and confirm
   the notes converge with no version prompt.
2. "Remove Download" in Files on the placed folder while syncing.
3. Background refresh timing.
4. A Lock Screen capture adopted on another device.
5. WebDAV on cellular, as a second target of the same vault (the bridge).
6. A device key change with one device offline that comes back a day later.

## 10. Phased plan

Sizes: S < 300 changed lines, M 300 to 1,000, L > 1,000 (moved lines count once).

| # | PR | Size | Depends on | Risk | TestFlight |
| --- | --- | --- | --- | --- | --- |
| P1 | `SempereSync`: move the engine, add `SyncRemote` and the WebDAV adapter, renames; no behavior change | L (moves) | — | a hidden behavior change. Mitigation: the move and rename commits are separate | **next build** (invisible) |
| P2 | `MemoryRemote`, the conformance suite, engine suites over transports, N-device stress | M | P1 | — | **next build** (tests) |
| P3 | `FolderRemote` + `EvictingFolderRemote` + eviction tolerance + `UbiquitousFolderHooks` (moving `CloudScan`, `CloudConflicts`, `CloudChanges`, `StorageLocation` logic) + `sempere sync folder` | L | P2 | eviction misjudged as absence. Mitigation: availability is checked before every judgment; property tests | **next build** (CLI only) |
| P4a | **Key-change safety gate**: `RewrapFaults`, keyring, claims, journal-upload rule, late-file window and quarantine, and the §6.4 suites (written first, against P4's rules) | L | P2 | — | — |
| P4 | Engine parity: `keys/`, `inbox/`, `summaries/<device>`, rewrap-replace; format.md text; security review | L | P1, P4a | security-sensitive. Mitigation: the gate | after the gate |
| P5 | App: working copy store + `SyncSession` + two-way WebDAV (no push-only; Download Again becomes Sync Now; the status model; arrivals into RemoteMerge; settings merged locally). Old WebDAV copies are not carried over | M to L | P1, P4 | first two-way writes into an open vault. Mitigation: `VaultFileLock`, two-device app tests | the build after next |
| P6 | App: folder targets (iCloud Drive and any folder), multiple targets per vault, New Vault / Open Folder / Add Target, the App Group root, quick capture to the local inbox | M | P3, P5 | provider behavior. Mitigation: owner checks 1, 2 and 5 | — |
| P7 | Delete in-place reading and `WebDAVFetcher` and their tests; port the hazard tests; rewrite docs/io.md and the CLAUDE.md gotchas | M (mostly deletions) | P6 | removing a path still used. Mitigation: `isCloudVault` reaching zero | — |
| P8 | BGAppRefresh and BGProcessing for every target, reachability, locked staging | M | P5 | iOS timing. Mitigation: owner check 3 | — |
| P9 | UI: details, Storage, Repair (including late files), the devices-per-target view | M | P5, P6 | — | — |
| P10 | Key changes for synced vaults in the app; delete `requireLocalKeyChanges`; outgoing-identity guard | S to M | P4a, P4, P5 | covered by the gate | — |

Critical path: P1 → P2 → P4a → P4 → P5 → P6 → P7. P3 runs alongside P4a. P8, P9 and P10 can run in
parallel after P5. Removing migration made P5 and P6 smaller (about 1 session less); the gate adds about
1 to 2. That is roughly 9 to 11 author sessions.

## 11. Decisions (2026-10-19) and remaining questions

| # | Question | Decision or recommendation |
| --- | --- | --- |
| Q1 | Where does the vault live on iOS? | **Decided:** hidden in the app's container; folders are sync targets ("least friction") |
| Q2 | Several targets per vault? | **Decided:** yes, in the engine, model and UI ("multiple backups is great") |
| Q3 | Download every attachment? | **Decided:** yes, always |
| Q4 | Locked background downloads: place or stage? | Recommended: **stage** until unlock (§4.1) |
| Q5 | Migrate existing vaults? | **Decided:** no migration. The owner re-imports, and old in-place vaults are not supported. An existing vault folder opens as a target through Open Folder… |
| Q6 | Restrictions on where a vault is placed? | **Decided:** none. Any folder works; provider correctness is the folder transport's job (§3.3) |
| Q7 | Evict a provider folder's copy after upload to save space? | Recommended: no for now; measure first |
| Q8 | Record each device's targets in the vault to detect islands? | Recommended: no format change; show devices per target |
| Q9 | A push-only mirror target in the app? | Recommended: the CLI only, until the web viewer ships |
| Q10 | Key changes while other devices are offline? | **Decided:** allowed, subject to the §6 review and its gate (P4a) |
| Q11 | Other providers? | **Decided:** "Other Folder…" for now, with the protocol extensible (§3.4) |
| Q12 (new) | How long is the late-file window (§6.2 F9)? | Recommended: **7 days**, then quarantine with Adopt and Export (never delete) |

## 12. Alternatives considered

- **Open placed vaults in place** (today's iCloud model, kept for provider folders). This would keep
  partial offline access and two read paths in the app. Rejected: the working copy plus a folder
  target gives the same placement freedom and keeps one path.
- **Keep iCloud in place and make WebDAV two-way only.** Rejected for the same reasons, and it leaves
  iCloud without the §9.1 checks.
- **CloudKit as the iCloud transport.** It needs the iCloud entitlement and a schema, and gives up a
  folder that the CLI and Finder can read. It could be an adapter later (§3.4).
- **Partial copies by default.** This contradicts "offline access is 100% necessary". Partial copies
  are only the transient state of a join.
