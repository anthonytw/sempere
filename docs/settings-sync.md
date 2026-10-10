# Settings sync through the vault

Status: design accepted by the maintainer (2026-10-09), with the file format he chose
the same day: a VS Code-style `settings.json`, encrypted in the vault. A first-release
feature. The normative format text is `format.md` §13; the file's JSON Schema is
`docs/settings.schema.json`. This document says why, what syncs, and how the app and
the CLI behave.

## 1. Goal

A user with an iPad and a Mac sets the paper, the title format of new notes, the
recording quality or the photo privacy option once, and every device that opens the
same vault follows. The settings travel exactly like the notes: inside the vault,
encrypted to the vault's keys, through whatever moves the vault (iCloud Drive, a Files
provider, WebDAV, a backup and restore).

- **No Apple key-value storage.** `NSUbiquitousKeyValueStore` and iCloud key-value
  storage are not end-to-end encrypted. Nothing about settings leaves the device except
  inside the vault.
- **No silent divergence.** A synced setting edited on one device changes it on every
  device that uses it. A device deviates only when the user says so, per setting.
- **Every setting syncs.** A setting that only some kinds of device use (mouse
  smoothing on a Mac) is still in the file; the others ignore it. Where the same setting
  should differ by kind of device, the file has a block per device type (section 2.2).
- **Settings, not state.** Device *state* never goes in the file: keys, Keychain items,
  Face ID or passkey enrolment, quick-capture key material, caches, bookmarks, window
  layout (section 5.3).

## 2. The file

### 2.1 Where and how it is stored

One file at the vault root, `settings.age`:

- age-encrypted to the vault's recipients, like every revision;
- inside, the revision body framing of `format.md` §4 (`SMPR`, version, HMAC tag under
  the vault secret, `gzip(JSON)`), with `settings` where a revision has its note id. The
  tag means only a holder of the vault secret can write a file the app accepts: anyone
  can age-encrypt to the public recipients, nobody else can tag;
- recoverable with stock tools, like a revision:
  `age -d -i key settings.age | tail -c +38 | gunzip | jq .`

### 2.2 The JSON

```json
{
  "$schemaVersion": 1,
  "$minReaderVersion": 1,
  "editor.defaultPaper": { "kind": "grid", "spacing": 20 },
  "newNote.titleFormat": "isoDateTime",
  "mouse.smoothing": "strong",
  "photos.removeMetadata": true,
  "[ipad]": {
    "editor.keepScreenOn": true
  },
  "[mac]": {
    "eraser.mode": "pixel"
  },
  "$meta": {
    "editor.defaultPaper":   { "modified": 1760025600000, "type": "ipad" },
    "newNote.titleFormat":   { "modified": 1760025600000, "type": "ipad" },
    "mouse.smoothing":       { "modified": 1760027400000, "type": "mac" },
    "photos.removeMetadata": { "modified": 1760025600000, "type": "ipad" },
    "history.thinAfterDays": { "modified": 1760029200000, "type": "mac" },
    "[ipad]": { "editor.keepScreenOn": { "modified": 1760025600000, "type": "ipad" } },
    "[mac]":  { "eraser.mode":         { "modified": 1760027400000, "type": "mac" } }
  }
}
```

- **Settings are flat dotted keys at the top level**, unscoped:
  `"editor.defaultPaper"`, `"mouse.smoothing"`. Each key is documented once (section 5)
  with the device types that use it. A device reads the keys it knows and ignores the
  rest: an iPad ignores `mouse.smoothing`, and keeps it in the file.
- **Type blocks** `"[mac]"`, `"[ipad]"`, `"[iphone]"` (like VS Code's `"[python]"`) are
  optional and only for the same key with a different value per device type. A key in
  a type block wins over the top level on devices of that type.
- **`"$meta"`** holds, per key (and per key inside each type block, under the block's
  name), when it was last written (`modified`, Unix milliseconds) and by which kind of
  device (`type`: `mac`, `ipad`, `iphone`; absent for the CLI). It drives the merge
  (section 3) and is kept out of the way: the CLI hides it. A key listed in `$meta` but
  absent from the settings is a **reset**: the setting was set back to its default.
- **`"$schemaVersion"`** and **`"$minReaderVersion"`** are integers: the writer's version
  of the keys, and the oldest reader that may read and write the file (section 6), both
  `1` for this version.
- Other members starting with `$` and keys this version does not know are kept as
  they are.

### 2.3 Resolution on a device

For each setting it uses, a device takes the first of:

1. its **local override** ("Only on This Device", section 4.3), which is never in the file;
2. the key in **its type's block** (`[mac]` on a Mac);
3. the key at the **top level**;
4. the **built-in default**.

A value of the wrong type or out of range for a known key (from a damaged file, a hand
edit or another version) is skipped with a logged warning, and resolution goes on to the
next step, so it ends at the default at worst. The rest of the file is used as usual: an
invalid value never makes the whole file unreadable.

## 3. Merge: per key, last writer wins

The merge is per key, never per file. A *slot* is one key at the top level or one key
inside one type block; each slot has its value (or none: a reset) and its `$meta` entry.

- For each slot, the side with the greater `(modified, type, value)` wins: `modified`
  as an integer (a slot without a `$meta` entry, written by hand, counts as older than
  any slot with one), then `type` as a string (absent lowest), then the canonical JSON
  of the value (sorted object keys; a reset lowest). This is a total order, so the merge
  of two files is the same whichever is read first (commutative), however reads are
  grouped (associative), and merging a file with itself changes nothing (idempotent).
  Every replica that has seen the same writes holds the same settings.
- **Keys nobody knows are kept.** A key or a type block this version does not know
  (written by a newer version, or a hand edit) is merged by the same rule and written
  back unchanged. `$schemaVersion` merges to the larger of the two.
- **Writing a slot** (an edit, a reset, a seed) gives it `modified = max(now, m + 1)`,
  where `m` is the `modified` the writer currently holds for that slot. An edit therefore
  always beats the value its writer saw, even when that device's clock is behind the
  clock of the device that wrote the old value. Two devices that edit the same slot
  without seeing each other's edit: the later clock wins (ties: the type, then the
  value), which is what "last writer wins" can mean without a coordinator.
- **Resets are writes too**: a reset is a slot like any other for the merge, so it is not
  undone by a device that still holds the old value.

**Concurrent writers and the file.** iCloud Drive, a Files provider or a WebDAV server
keeps one copy of a mutable file: when two devices write `settings.age` at about the same
time, one copy may replace the other. Each device keeps its own merged copy of the
shared settings (section 4.1), so nothing is lost: whenever a device reads the file, it
merges it with its copy, and if the result differs from the file (the file lacks a slot
the device holds, or holds an older one), it writes the merged result back. A change
lost in a file-level race comes back the next time its device syncs, and every device
agrees once each has read the others' writes. WebDAV sync merges the two copies itself
when both sides changed (section 8).

## 4. On a device

### 4.1 Opt-in per device and per vault

Settings ▸ **Sync Settings with This Vault** (off by default). It is per device and per
vault: a device that opens two vaults syncs with the one(s) it was switched on for, and
applies a vault's settings while that vault is open.

A device knows its type: a Mac (the Mac Catalyst app, or the iPad app on a Mac) is
`mac`, an iPad `ipad`, an iPhone `iphone`. All devices of a type share that type's block:
the user's two Macs, or a family member's Mac on the same vault. Devices are not told
apart by name (later, section 5.4); a single device differs through a local override.

The device keeps, per vault, outside the vault (`UserDefaults` under the vault id, like
the backup record): whether sync is on, its local overrides, its merged copy of the
shared settings, and the values it last applied (to tell its own edits from values it
received).

### 4.2 Turning it on

- **The file has nothing for this device** (no `settings.age`, or no slot of any setting
  this device uses, at the top level or in its block): this device's current values
  become the shared set, written at the top level.
- **The file has settings for this device**: the app compares what they resolve to with
  this device's values. When they agree, sync turns on silently. Otherwise it shows each
  setting that differs (the vault's value and this device's) and offers:
  - **Use the Vault's Settings** (the default): this device takes the shared values.
  - **Replace the Vault's Settings with This Device's**: every setting this device uses
    is written with this device's value, where it resolves from (its type block when
    the key is there, else the top level).
  - Cancel leaves sync off and changes nothing.
- A setting the file has no slot for (a type's first device, a setting added by a later
  version) is seeded at the top level from this device's value without asking.
- Turning sync off keeps this device's current values and stops reading and writing the
  file. Its overrides are forgotten; turning it on again starts over with the step above.

### 4.3 Synced and overridden settings

Each setting on a device with sync on is **synced** or **overridden** ("This Device
Only"):

- **Editing a synced setting changes the shared value** for every device that uses it:
  the slot it resolves from (this type's block when the key is there, else the top
  level). That is what sync means; there is no silent local divergence.
- **Only on This Device** (a row's context menu, or the control at the end of the row):
  the setting keeps its current value and becomes overridden. Later edits stay on this
  device, later shared values do not change it. Overridden rows show a small **This
  Device** badge, which is also a menu with **Use Synced Value**. The override lives only
  on this device and needs no device name: it is never written to the file.
- **Use Synced Value** ends the override: the setting takes the shared value (or, if the
  vault has none for it, this device's value becomes the shared one). Setting an
  overridden row back to the shared value does **not** relink it: the state is explicit,
  never inferred from equal values. Only Use Synced Value clears it.
- **Only on iPads** (Macs, iPhones: this device's type): writes the current value into
  this type's block, so devices of this type keep it while the others follow the top
  level. Such rows show the type as a badge, a menu with **Use on All Devices**, which
  resets the block's slot so the top level applies again.

Settings edited outside the Settings screen (the paper picker's "use as default", the
layout choice of the new-note sheet, the eraser in the editor) follow the same rules.
Overrides are chosen in Settings.

### 4.4 When the app reads and writes the file

- It reads `settings.age` when the vault is unlocked, when Settings opens and when the app
  returns to the foreground; in iCloud Drive it downloads the file first, like `vault.json`.
- It writes when a synced setting changed on this device (about a second after the last
  change, so dragging through a picker writes once), and when a read found the file
  behind this device's copy (section 3).
- Settings added by a later app version: the first device with that version and sync on
  writes its current value as the shared one when the vault has no slot for it.

### 4.5 Read-only, legacy and untrusted vaults

Writing `settings.age` is a vault write: it is refused where every write is (`format.md`
§7.3 read-only vaults, §3.3.2 legacy vaults, §2.1 a tampered recipients list). The app
then pauses settings sync and says why under the switch; edits made meanwhile are written
once the vault is writable again (they are detected against the last applied values).
Reading and applying need the vault unlocked.

## 5. The settings

Every setting syncs (maintainer, 2026-10-09). Each is one top-level key; **Types** says
which devices use it. Any key may also appear in a type block.

### 5.1 Used by every device

| Key | Setting (Settings ▸ section ▸ row) | Values | Default |
| --- | --- | --- | --- |
| `handwriting.recognize` | General ▸ Recognize Handwriting | `true`, `false` | `true` |
| `newNote.titleFormat` | New Notes ▸ Title | `dateAndTime`, `dateOnly`, `isoDateTime`, `weekday`, `custom`, `blank` | `dateAndTime` |
| `newNote.titlePattern` | New Notes ▸ Title ▸ Pattern (custom) | a pattern `notes new --title-format` accepts | `yyyy-MM-dd HH:mm` |
| `editor.defaultPaper` | New Notes ▸ Paper | a paper object (`format.md` §5.4.2) | ruled |
| `editor.defaultLayout` | New Notes ▸ Layout (also the new-note sheet) | `letter`, `a4`, `pagelessLetter`, `pagelessA4` | `letter` |
| `editor.compactPalette` | Compact Palette (editor) | `true`, `false` | `false` |
| `eraser.mode` | the eraser's mode, last chosen (editor) | `object`, `pixel` | `object` |
| `eraser.objectRadius` | Object Eraser Size (editor) | 4, 8, 16, 32 | 8 |
| `recording.codec` | Recording ▸ Format | `aac`, `he-aac`, `alac` | `aac` |
| `recording.bitRate` | Recording ▸ Quality | 24000, 32000, 48000, 64000, 96000, 128000 | 64000 |
| `recording.sampleRate` | Recording ▸ Sample Rate | 16000, 22050, 32000, 44100, 48000 | 48000 |
| `recording.channels` | Recording ▸ Channels | 1, 2 | 1 |
| `transcription.enabled` | Transcription ▸ Transcribe Recordings | `true`, `false` | `false` |
| `transcription.language` | Transcription ▸ Language | a locale identifier, or `null` (same as the device) | `null` |
| `math.recognize` | Convert Handwriting to Math | `true`, `false` | `false` |
| `photos.removeMetadata` | Photos ▸ Remove Location and Camera Data | `true`, `false` | `true` |
| `history.thinAfterDays` | Version History ▸ Thin Autosaves Older Than | 7, 14, 30, 90, 365, 0 (never) | 30 |
| `search.transcripts` | Search Recording Transcripts (the search field) | `true`, `false` | `false` |
| `rewrap.onAdd` | Device Keys ▸ When Adding a Device | `header`, `reencrypt` | `header` |
| `rewrap.onRemove` | Device Keys ▸ When Removing a Device or Upgrading | `header`, `reencrypt` | `reencrypt` |
| `backup.reminderDays` | Backups ▸ Remind Me (once the device has a backup folder) | 0 (off), 1, 3, 7, 14, 30 | 0 |

Recognition and transcription still run on each device: one without the language model
does what it can, as today. The rewrap modes are policies of the vault; choosing the
weaker removal mode still asks for confirmation on the device where it is chosen, and
the other devices follow it.

### 5.2 Used by some device types

| Key | Setting | Types | Values | Default |
| --- | --- | --- | --- | --- |
| `editor.keepScreenOn` | General ▸ Keep Screen On | `ipad`, `iphone` | `true`, `false` | `false` |
| `mouse.smoothing` | General ▸ Smooth Mouse Strokes | `mac` | `off`, `light`, `strong` | `light` |
| `quickCapture.notebook` | Quick Voice Notes ▸ Notebook | `ipad`, `iphone` | a notebook path | `Inbox` |
| `quickCapture.transcribe` | Quick Voice Notes ▸ Transcribe Voice Notes | `ipad`, `iphone` | `true`, `false` | `true` |
| `appearance.icon` | App Icon (where iOS offers alternate icons) | `ipad`, `iphone` | `keyholeNib`, `cemeteryDoor`, `shadowS`, `inkWind` | `keyholeNib` |

The quick-capture settings apply while quick capture is on for the vault on that device;
switching it on or off is not a setting (it creates or deletes the device's capture key,
which is state).

The app icon is applied through iOS, which tells the user each time it changes; the Mac
app keeps its one icon. Not built yet, and settings when they come: Pencil options such
as the double-tap action (`pencil.doubleTap`, `ipad`), and how a device prefers to
unlock (`security.unlock`); the remembered key itself stays state.

### 5.3 Device state (never in the file)

| State | Why |
| --- | --- |
| Keys, remembered keys, Keychain items, Face ID / passkey enrolment | secrets and this device's hardware |
| Quick capture on or off, its capture profile and capture key | key material (`format.md` §11) |
| Backup folder (bookmark) and last backup results | a folder this device picked |
| Tool palette shown, page strip shown, column layout, sidebar selection, saved windows | what this device's windows show at the moment |
| Last equation style in the math editor, recent searches, Recently Recognized | editor and search memory |
| Downloaded math models and transcription language models | files on this device |
| Cache size limits, last thinning run, attachment index | this device's disk and bookkeeping |
| PencilKit's own saved tools (`PKPaletteNamedDefaults`) | PencilKit's state, partly reset by the app |
| Sync Settings with This Vault, and the local overrides | the sync switch itself |

A new setting is added to the registry (`SharedSettingsCatalog` in
`Sources/Sempere/SharedSettingsCatalog.swift`) with its types, values and default, a
row in the tables above, and the regenerated schema (section 6).

### 5.4 Later

Telling devices of the same type apart by name ("my Mac" and "the family Mac"), so that a
setting can be scoped to one named device. Until then all devices of a type share its
block, and the local override is the way for one device to differ (`docs/ROADMAP.md`).

## 6. Schema, versions and compatibility

### 6.1 JSON Schema

`docs/settings.schema.json` describes the file. It is generated from the registry
(`SharedSettingsSchema`, also `sempere settings schema`), and a test fails when the
committed file differs. Readers validate with the registry the schema is made from (the
same rules); `sempere settings validate` reports every problem.

### 6.2 Compatibility rules (maintainer, 2026-10-09)

1. **Changes are additive by default**: new keys only. Older apps ignore keys they do not
   know (and keep them, rule 5). A test keeps a snapshot of each version's registry
   (`Tests/SempereTests/Fixtures/settings/registry-v<N>.json`) and fails when a key of an
   older snapshot is no longer in the registry, as a key or a legacy key.
2. **Renames and meaning changes use a dual-write window.** The newer app writes both the
   old and the new key, kept equal, for several releases (`SharedSettingSpec.legacy`: the
   old key and the mappings between the two values); the old key is removed only later.
   On a device that knows both, a setting resolves from whichever of the two slots was
   written last, so an older app's edit of the old key still counts. Migrations add the
   new key from the old one and never strip a key older apps still read: a step that
   removes a key is allowed only in a migration that raises `$minReaderVersion` past every
   reader of that key (a test checks this).
3. **Two numbers in the file**: `$schemaVersion`, the version of the writer that wrote it,
   and `$minReaderVersion`, the oldest reader that can safely read **and write** it. Both
   merge to the larger value. `$minReaderVersion` is raised only for a genuinely breaking
   change, as a deliberate, reviewed act: the table below must have a row for the current
   value (a test fails otherwise), naming the change and why it cannot be additive.
4. **A reader older than `$minReaderVersion`** pauses settings sync for that vault: it does
   not read, apply or write the file (never touches it), keeps using its last good synced
   values stored on the device (nothing resets), and shows a banner: "Settings sync is
   paused: this vault's settings need a newer Sempere. Update the app to resume." Once
   updated, the next pass resumes. The CLI refuses with exit 7.
5. **An older but compatible reader** (its version ≥ `$minReaderVersion`) saving a newer
   file keeps every unknown key, type block, `$` member and `$meta` entry verbatim, and
   both version numbers.

### 6.3 Versions and migrations

- **`$schemaVersion`** counts changes to the keys' names and meanings. A change of a key's
  name or meaning adds an ordered migration `vN → vN+1` (`SharedSettingsMigrations`): it
  copies (or splits) the old key into the new one, maps values, and keeps the old key
  (rule 2). Migrations run on read, on the in-memory copy; the result is written back only
  when the device next saves. Each copy carries the slot's `$meta` unchanged, so devices
  that migrate the same file get the same result. Every migration has a test, and every
  version a fixture (`Tests/SempereTests/Fixtures/settings/v<N>.json`).
- **A newer `$schemaVersion`** than the device knows: it does not migrate and does not
  rewrite what it does not understand. It reads the keys it knows, and on save writes
  only the slots it changed, keeping everything else verbatim (rule 5).
- **The vault format** is unchanged: no format bump and no `features` entry (that would
  stop every older writer, `format.md` §2). `settings.age` is a compatible extension
  (`format.md` §7.5), an unknown file to older readers.

| `$schemaVersion` | Date | Change | Migration |
| --- | --- | --- | --- |
| 1 | 2026-10-09 | first version | none |

| `$minReaderVersion` | Date | Breaking change and why it could not be additive |
| --- | --- | --- |
| 1 | 2026-10-09 | first version: every reader of the format reads it |

## 7. The CLI

```
sempere settings list     [--type mac|ipad|iphone] [--all] [--json]
sempere settings get      KEY [--type T] [--json]
sempere settings set      KEY VALUE [--type T] [--json]
sempere settings reset    KEY [--type T] [--json]
sempere settings edit     [--json]
sempere settings validate [--json]
sempere settings schema
```

- `list` shows the top level, each known key with its value or default; `--type T`
  shows what a device of type T resolves to (and where from); `--all` adds unknown keys
  and type blocks. `get` prints one key's value (resolved for `--type`).
- `set` and `reset` write the top level, or the type block with `--type`. `set`
  validates the value against the registry (`true`/`false`/`on`/`off` for switches,
  numbers, names; JSON or a kind name for the paper) and refuses keys it does not know.
- `edit` opens `$EDITOR` (`$VISUAL` first, else `vi`) on the decrypted JSON without
  `$meta`, in a private temporary file it deletes afterwards. On save it validates the
  result, refuses an invalid file without writing anything, and records each changed key
  in `$meta` before re-encrypting.
- A file whose `$minReaderVersion` is newer than the CLI is refused (exit 7), never
  rewritten.
- `validate` checks the file against the schema: unknown keys and blocks are
  information, invalid values of known keys are errors (exit 1).
- `$meta` is never shown. **The CLI has no device overrides**: it is not a device that
  applies settings, it edits the shared file that devices with sync on follow (their
  local overrides still win on them). Writes record no device type and follow the merge
  rule above. Exit codes as for every command (`docs/cli.md`): 5 legacy vault, 6
  untrusted recipients, 7 read-only.

## 8. The rest of the vault

- **Recipient changes** (`format.md` §3.3.1): `settings.age` is rewritten with the
  revisions (new recipients; re-tagged under a rotated secret after verifying under the
  previous one). A file that cannot be read or verified is reported, left as it is, and
  does not keep the journal: the next settings write replaces it.
- **Backups**: `sempere backup`, `restore` and the app's Backups copy `settings.age` like
  `vault.json`.
- **WebDAV sync**: `settings.age` is synced as a mutable file. When both sides changed and
  the vault is unlocked, the sync merges them (section 3) and writes the result to both
  sides; locked, it keeps both and reports a conflict, as for `vault.json`. Push-only
  mirrors upload the local copy. A copy that does not verify never replaces one that does.
  A copy that needs a newer reader is never opened: it is mirrored byte for byte over a
  copy this version can read (a newer app wrote it, and older apps pause instead of
  writing), which `format.md` §7.3 allows of any reader.
- **iCloud Drive**: the app downloads `settings.age` before reading it.
- **Web viewer**: ignores the file.
- **Older apps and CLIs** ignore unknown files (`format.md` §1), so they keep working with
  a vault that has `settings.age`. They do not rewrap it in a recipient change: the file
  is then left encrypted to the previous keys and tagged under the previous secret, newer
  readers report it as unreadable, and the next write from a device with sync on replaces
  it from that device's copy. A device whose own keys are the stale ones (the vault stayed
  open there while another device changed them, so `vault.json` on disk no longer matches
  what it holds) never replaces the file: it waits until the vault is reopened
  (`Vault.keysMatchManifestOnDisk`). A device removed by such an older app can read that stale
  copy (settings only, no note content) until it is replaced.

## 9. The app

- Settings gains a first section, **Sync Settings with This Vault**: the switch, and under
  it what it does and whether sync is paused (locked, read-only, a tampered device list,
  a file that needs a newer Sempere: the banner of rule 4) or found a settings file it
  cannot read.
- Rows of settings get a context menu (Only on This Device, Only on iPads, Use Synced
  Value, Use on All Devices) and, when overridden or type-specific, a badge (`.help` on
  the Mac). Spanish strings for every new string.
- The logic is in `Sources/Sempere` (`SharedSettings`, `SharedSettingsCatalog`,
  `SharedSettingsMigrations`, `SettingsSyncState`: merge, resolution, first enable,
  overrides, passes), tested on Linux. The app maps keys to its `UserDefaults` values
  (`SettingsSyncBridge`) and runs the passes (`AppModel+SettingsSync`).

## 10. Tests

- Core (`SharedSettingsTests`): merge is commutative, associative and idempotent
  (property test over random slots, type blocks included), the write rule beats a skewed
  clock, resets win and lose by the same order, unknown keys, blocks and `$` members
  survive a merge and a rewrite, resolution order (override > block > top > default),
  dual-written legacy keys, the compatibility matrix (every older reader, by its version
  and registry snapshot, loads every newer fixture and keeps what it does not know), the
  `$minReaderVersion` refusal and its doc row,
  invalid values fall back with a warning, limits and hostile files fail with typed errors
  (and a fuzz target), the tag binds the file, recipient changes rewrap the file, read-only
  and legacy vaults refuse writes; the schema file matches the registry; the migration
  machinery (renames, remaps, splits, a newer version left alone) and the v1 fixture.
- Device logic (`SettingsSyncStateTests`): the pause when the file needs a newer reader
  (nothing applied or written, last values kept); first enable on an empty vault (seed) and on a
  vault with settings (agree, use the vault's, replace the vault's); override lifecycle;
  type blocks (only on this type, use on all); passes push local edits to the slot they
  resolve from, apply remote ones, seed new keys, write back a file behind its copy.
- CLI (`CLISettingsTests`): list/get/set/reset/edit/validate/schema with `--json` and
  `--type`, validation errors, unknown keys preserved, `$meta` hidden.
- WebDAV (both sides changed: merged; locked: conflict copy) and backup (copied, restored).
- App (CI): the bridge round-trips every key through `UserDefaults`, and the model's
  passes against a temporary vault.
