# The `sempere` command line

The Linux and macOS face of Sempere: keys, vault management, note editing,
verification, export and recovery. Everything the app does to vault data can
be done here and scripted with `--json`; only the drawing itself needs the
app. It builds with `swift build -c release --product sempere`
and CI publishes a static Linux binary. The executable only parses arguments,
talks to the terminal and sets exit codes; everything else lives in
`Sources/Sempere` and `Sources/SempereRender`.

## Global conventions

| Option | Meaning |
| --- | --- |
| `--vault PATH` | The vault directory (`*.sempere`). Env `SEMPERE_VAULT`. |
| `--identity FILE` | This device's key file (`vault init`, `device init`), or any age identity file. Repeatable. Env `SEMPERE_IDENTITY` (one path). Default: this machine's device key for the vault. |
| `--recovery-key FILE` | Read the vault with its recovery key: the kit's identity file, or the vault's passphrase copy `keys/recovery-*.key.age`. Read-only. |
| `--root HEX` | The vault's root fingerprint (64 hex digits, or the kit's 16 groups; spaces and the groups' `(xxxx)` checksums are ignored) to check a `--recovery-key` read against. |
| `--passphrase-env VAR` | Name of the environment variable holding the passphrase: of a passphrase-wrapped device key, or of the recovery key's passphrase copy. |
| `--json` | Machine-readable output where it makes sense (everything except `recover` and `keys generate` without `--out`). |
| `-q`, `-v` | Quieter (data only, or only problems) / more detail. |
| `--version`, `--help` | On every command. `--version` prints `sempere VERSION`, then the copyright and the GPL notice (no warranty; free to redistribute under the GPL v3 or later) and links to the license and `SECURITY.md`; `sempere about` adds the rest. |

`--vault`, `--identity`, `--recovery-key`, `--root` and `--passphrase-env`
apply to the commands that open an existing vault. Times are printed in your local time zone with an offset;
`--json` uses UTC (`Z`).

**Getting a key.** Every vault file is encrypted to the vault identity
(`format.md` §3.1, §15.2), which the vault key `K_e` gives; `vault.json`
wraps `K_e` once for each listed device and once for the recovery key. A
command opens the vault with, in order:

1. `--recovery-key FILE`: the recovery key (the kit's identity file, or the
   passphrase copy, whose passphrase comes as below). It takes precedence over
   `--identity`. The vault is then **read-only** (every write exits 7) and keeps
   no trust record; `vault.json` is checked against `--root`, else the root in
   the passphrase copy, else nothing (a warning says so), and exits 6 when it
   does not check.
2. `--identity` files (or `$SEMPERE_IDENTITY`): a device key file (its
   signing keys come with it, which the home device needs to approve and
   rename devices) or any age identity file whose key is listed.
3. This machine's device key for the vault,
   `$XDG_STATE_HOME/sempere/devices/<vault id>/device.key` (mode 0600 in a
   0700 folder), written by `vault init` or `device init`. A
   passphrase-wrapped one (`device.key.age`, scrypt work factor 18) is opened
   with the passphrase from `--passphrase-env VAR`, else `$SEMPERE_PASSPHRASE`,
   else a no-echo prompt on the terminal; commands that only may read notes
   (`vault info`, `devices list`) ask for it only when it is scripted.

A key that is not listed in `vault.json` exits 4 ("this device has not joined
the vault"); with no key at all, a command that needs one exits 4 and says to
join (`device init`), pass `--identity` or read with `--recovery-key`. A
passphrase never goes on the command line. Device keys never leave the
machine: no command prints or exports them. Secret keys are printed only by
`keys generate`, `vault init --recovery-out` (into its file), `keys paper`
(into its PDF) and `keys derive` (from a key you give it).

**Exit codes**

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Generic failure (I/O, bad input, corrupt file, refusing to overwrite). |
| 2 | Usage error (unknown option, missing vault, a passphrase too easy to guess for the passphrase copy). |
| 3 | `vault verify` or `backup verify` found problems, a restored vault is not healthy, or `backup status --max-age` found no complete backup in that many days. |
| 4 | Cannot decrypt: wrong key or passphrase, no key available (no device key, no identity, no passphrase and no terminal to ask, or a `--passphrase-env` variable that is not set), or a key `vault.json` does not list (this machine has not joined, or its approval has not arrived). |
| 6 | Untrusted device list: `vault.json` does not check on this machine (`format.md` §2.1: changed without the vault key, not signed by the home device, an entry gone under the same epoch, older version markers, another root or epoch than the one this machine pinned, a trust record that does not read, or a join this machine has not confirmed yet: `sempere device confirm`). Every command that would write refuses (nothing is written), `vault verify` exits 6, and `sync webdav` exits 6 when it rejected a remote `vault.json`. Reading notes still works. |
| 7 | Read-only vault: it holds content of a newer format version (format.md §7), so this version may read it but not change it; or it was opened with the recovery key (`--recovery-key`), which never writes. The message says why (`format`, `features`, notes a newer version wrote, or the recovery key). |
| 8 | Removed: this machine's device is not on the vault's newest device list, and it verified the change that left it out (key hierarchy design §5.5: a removal by the home device, or a takeover). It writes nothing. The message names who made the change. A takeover that re-admits the device undoes it. |

Exit code 5 is unused. A `vault.json` that lists a classic X25519 key is
invalid (`format.md` §2, §3.1): every command that opens the vault fails with
exit 1 before asking for a key.

**Vaults of a newer format version** (format.md §7) open read-only. A vault
whose `vault.json` names a later `format` (`sempere/2`) or a format extension
this version does not know (`features`) prints one warning on stderr
(`sempere: warning: read-only: …`) and every reading command works: `vault
info`, `vault verify`, `notes list`/`show`/`search`/`history`, `search`,
`export`, `recover`, `blobs list`/`verify`/`extract`, `backup`. What a newer
version wrote is shown as far as this version understands it: unknown ops,
fields and snapshot elements are skipped, a revision with a later body version
is left out, and every such thing is reported. Every command that would write
(`notes new`/`rename`/`tag`/`move`/`paper`/`delete`/…, `pages`, `items`,
`attach`, `import`, `snapshot`, `compact`, `blobs add`/`copy`/`gc`/`repair`,
`devices approve`/`rename`, `vault label`, `inbox enable`/`import`,
`recognize`, `transcribe`) exits 7 without changing a file. `vault index`
exits 7 too unless it writes elsewhere (`--out FILE` or `-`). Newer
*revisions* in a version-1 vault (a sync can deliver them before the new
`vault.json`) make the run read-only from the moment it reads them: a write to
such a note, and any write after it in the same run, exits 7.

`--json` says so:

- `vault info --json` adds `format`, `features`, `readOnly` (bool) and
  `readOnlyReasons` (sentences), from `vault.json` alone;
- `vault verify --json` adds `readOnly` and `readOnlyReasons` after reading
  everything; each newer revision is a file with status `newer` (healthy) and
  a detail saying what was skipped;
- every note object (`notes list`, `notes show`, …) has `readOnly` (the vault
  or the note is read-only) and, for a note a newer version wrote, `newer`:
  `{revisions, unreadable, skippedOps: {name: count}, skippedElements,
  formats: {id: count}, features: {name: count}}` (names cut to 64 characters,
  at most 32 distinct, the rest under `…`); `notes show --json` also has
  top-level `readOnly` and `readOnlyReasons`.

Errors go to stderr, one line each, prefixed `sempere:`. A usage error (exit
2) ends with the command's help to read, e.g. `sempere: --page counts from 1
(see 'sempere attach image --help')`.

**Environment**

| Variable | Use |
| --- | --- |
| `SEMPERE_VAULT` | Default for `--vault`. |
| `SEMPERE_STORE` | Default for `--store` ([Vault store](#vault-store)). |
| `SEMPERE_IDENTITY` | Default identity file. |
| `SEMPERE_PASSPHRASE` | Passphrase of a passphrase-wrapped device key, or of the recovery key's passphrase copy, for scripts and tests. |
| `SEMPERE_TITLE_FORMAT` | Default for `notes new --title-format` ([Editing notes](#editing-notes)). |
| `SEMPERE_PDFTOPPM` | Poppler's `pdftoppm` for PDF page backgrounds in SVG/PNG exports (default: `pdftoppm` on `PATH`; [PDF page backgrounds](#pdf-page-backgrounds)). |
| `SEMPERE_PDFTOTEXT` | Poppler's `pdftotext` for the text of imported PDF pages (default: `pdftotext` on `PATH`; [`import pdf`](#import-pdf)). |
| `SEMPERE_WEBDAV_PASSWORD` | The WebDAV password, unless `--password-env` names another variable ([Sync](#sync)). |
| `SEMPERE_PROGRESS` | `always` or `never`: the `sync webdav` / `sync folder` progress line on stderr regardless of whether it is a terminal ([Sync](#sync)). |
| `VISUAL`, `EDITOR` | The editor `settings edit` opens (default `vi`; [Shared settings](#shared-settings)). |
| `SEMPERE_BUNDLED_FONTS` | The directory of the fonts shipped with the CLI ([Text in exports](#text-in-exports)). |
| `SEMPERE_FONT_DIR` | An extra directory of font packs, searched first ([Text in exports](#text-in-exports)). |
| `XDG_STATE_HOME` | Where this machine's state lives under `sempere/` (`device.json`, device keys in `devices/<vault id>/`, trust records in `trust/`, sync and capture state; default `~/.local/state`). |
| `XDG_CACHE_HOME` | Where the summary cache lives (default `~/.cache`; [Notes](#notes)). |
| `XDG_DATA_HOME` | Font packs under `sempere/fonts` (default `~/.local/share`; [Text in exports](#text-in-exports)), and the default vault store `sempere/vaults` ([Vault store](#vault-store)). |

## Commands

### Keys

```
sempere keys generate [--out FILE]
sempere keys show FILE
sempere keys paper --out KIT.pdf --identity RECOVERY.txt [--vault V] [--passphrase [--work-factor 15...20]]
                    [--paper letter|a4]
sempere keys derive --epoch-key-file FILE [--epoch N] [--vault-id UUID] [--capture-fingerprint HEX]
```

- `generate` writes an `age-keygen`-style identity (mode 0600, refuses to
  overwrite) and prints the public key. Without `--out` the identity goes to
  stdout and the public key to stderr. Keys are always post-quantum
  MLKEM768-X25519 (`AGE-SECRET-KEY-PQ-1...`, recipient `age1pq1...`, as
  `age-keygen -pq` makes); vaults take no other kind. Decrypting their files
  with the stock CLI needs `age` 1.3 or later; on Apple platforms the key
  type needs macOS 26. Use it for a recovery key you choose yourself
  (`vault init --recovery-key`); device keys are made by `vault init` and
  `device init`.
- `show` prints the public key (`age1...` or `age1pq1...`) of an identity file.
- `paper` writes a two-page printable PDF recovery kit for a vault's
  **recovery key** (mode 0600, refuses to overwrite). The key is the one
  `--identity` names (required, exactly one; exit 2 otherwise): the file
  `vault init --recovery-out` wrote. No device
  keeps the recovery key, so a kit can only be printed while you still have
  that file; delete it, and the PDF, once the kit is printed. With `--vault`
  the key must be the vault's recovery entry (`format.md` §2; else exit 4:
  a device key is refused) and the kit carries the vault's name, id, creation
  date and root fingerprint.
  Page 1: the key as a QR code (byte mode, error correction Q, version 7 for
  the `AGE-SECRET-KEY-PQ-1…` line), the key as text in numbered lines with a
  4-digit checksum per line, the public key's length, first characters and
  digest, a boxed warning that **the sheet is the vault's recovery key**, and
  with `--vault` the root as 16 groups of 4 hex digits, each with its line
  checksum. Page 2: recovery read-only with `sempere` (`vault verify` and
  `export` with `--recovery-key key.txt --root …`), and with stock tools: the
  frozen script of `format.md` §15.13 byte for byte, with the root's QR code
  (`sempere-root:<vault id>:<64 hex>`) beside it.
  The line checksum is the first 4 hex digits of SHA-256 of the line as typed:
  `printf '%s' 'LINE' | sha256sum | cut -c1-4`. The key also carries its own
  Bech32 checksum (its last 6 characters, a BCH code over the whole key): any
  typo of up to 4 characters makes `age` reject it, but only the line checksums
  say which line is wrong. The public key is 1959 characters and cannot be
  read or typed from paper, so the sheet prints its first characters, its
  length and the first 16 hex digits of its SHA-256; page 2 gives
  `age-keygen -y key.txt | tr -d '\n' | sha256sum | cut -c1-16` to check the
  rebuilt key against it. Kits are printed only for post-quantum keys: a
  classic `AGE-SECRET-KEY-1…` key is refused ("create a new key", exit 2).
  `--passphrase` prints a passphrase-wrapped copy of the key instead (armored
  age, scrypt, `--work-factor` 15 to 20, default 18; QR error correction M),
  under a passphrase you choose (`--passphrase-env VAR` / `$SEMPERE_PASSPHRASE`
  / the terminal, confirmed). It wraps only the secret key line, so the
  public key never ends up in the QR code (it would not fit). The command
  decrypts what it prints before writing the PDF. That sheet is safe to store
  less carefully, but useless without the passphrase. `--json` emits `path`,
  `variant` (`plain` or `passphrase`), `publicKey`, `vaultId`, `qrVersion`,
  `qrErrorCorrection` and `lines`.
- `derive` prints the key schedule of one vault epoch key `K_e` (`format.md`
  §15.2; `docs/design/key-hierarchy.md` §2): the vault identity
  (`AGE-SECRET-KEY-PQ-1…`) and its recipient, the derived keys (`tagKey`, `blobNameKey`,
  `listKey`, `markersKey`, `epochId`, `pendingKey`, the link seeds), the epoch link public keys, with
  `--capture-fingerprint` that device's capture key (`format.md` §11.1), and with `--vault-id` the wrap plaintext (and at
  `--epoch 1` the root fingerprint). `K_e` is read from a file of 64 lowercase hex digits (`-` for
  standard input), never from the command line. It reads and writes no vault; it exists so another
  implementation can be checked against this one, and `--json` uses the field names of
  `Tests/SempereTests/Fixtures/epoch-vectors.json`. The output holds secret keys.

**Removed.** `keys export` is gone: device keys never leave their device, and
the vault holds no key file to export (`keys/` holds only the recovery key's
passphrase copy). The app's key management (adding, removing and replacing
keys, joining devices) is stubbed until phase KH5 of the key hierarchy; the
CLI's `device` and `devices` commands are the way to join a device for now.

### Devices

```
sempere device init [--name TEXT] [--kind WORD] [--passphrase]
sempere device confirm WORD WORD WORD WORD WORD WORD
sempere devices list
sempere devices approve WORD WORD WORD WORD WORD WORD
sempere devices rename ID NAME
sempere devices remove ID... [--no-pull] [--password-env VAR]
sempere devices handoff ID [--no-pull] [--password-env VAR]
sempere devices status [--export DIR] [--forget-sightings [--all]]
sempere devices takeover --recovery-key FILE [--root HEX] [--keep ID]... [--keep-listed] [--name TEXT] [--kind WORD] [--yes]
sempere recovery replace --recovery-out FILE [--keep ID]... [--remove ID]... [--old-recovery-key FILE] [--recovery-passphrase] [--yes]
sempere set-aside list | export [SHA...] --to DIR | keep SHA... --yes | clear (SHA... | --superseded) --yes
```

A vault has one **home** device, the one that changes its device list: the
machine that created it (`docs/design/key-hierarchy.md` §5.6). Joining another
device takes words typed both ways (`format.md` §15.12, design §6.2):

1. On the new machine, `device init --vault V` generates its device key and
   signing keys into `$XDG_STATE_HOME/sempere/devices/<vault id>/device.key`
   (mode 0600; with `--passphrase`, passphrase-wrapped as `device.key.age`,
   work factor 18), writes the join request `joins/<id>.join.json` into the
   vault folder (create-only; no key needed) and prints six words. `--name`
   (at most 40 characters, default `sempere CLI`) and `--kind` (a lowercase
   word, default `cli`) go into the request. It refuses (exit 1) when this
   machine already has a device key for the vault. `--json`: `device`,
   `deviceKey`, `request`, `words`.
2. The request must reach the home device's copy of the folder (a shared
   folder, `vault merge-copy`, or a sync: `sync webdav`, `sync folder` and
   `store sync` carry `joins/`). There, `devices approve --vault V WORD…`
   finds the request whose commitment the typed words give (typing, not
   comparing, so a near match is not waved through), appends the device to
   `vault.json` with a wrap of the vault key and home's signature, deletes the
   request, and prints six words back. No file is re-encrypted. Only home
   approves (exit 1 elsewhere, naming the home device). It refuses a request
   of another vault, a key that is not post-quantum, a key already listed, or
   one whose id is a listed device's. `--json`: `device`, `name`, `reply`.
3. Once the new `vault.json` reaches the new machine (a sync with its device
   key takes the approval that lists it, although the machine's copy does not
   list it yet), `device confirm --vault V
   WORD…` checks the words against its own commitment and the vault's root and
   epoch, and pins the vault in this machine's trust record: from then on it
   writes to the vault. Exit 4 when this machine is not listed yet, 1 when the
   words do not match. Until it confirms, the machine reads the vault but
   every write exits 6 (`rootUnconfirmed`). `--json`: `device`, `root`.

- `devices list` prints every device (id, kind, name, when it was added and
  by whom, when it last completed a two-way sync (from its own summaries file,
  with the key), "manages devices" for home, "this device"), the recovery kit
  (when it was created, and whether a passphrase copy is in `keys/`), and the
  join requests waiting in `joins/`. It works without a key (names as stored,
  unchecked); with one, `vault.json` is checked first and the `Device list:`
  line says how, and a line says when this machine is not on the newest list
  or waits for a device change to be verified. `--json`: `devices` (`[{device:
  {id, name, kind, added, addedBy, home, fingerprint}, thisDevice, lastSynced}]`),
  `recovery` (`{added, passphraseCopy}`), `joinRequests` (`[{file, id, name,
  kind, created, problem}]`), `list` (as in `vault info`), `thisDeviceIsHome`,
  `unlisted` and `waiting`.
- `devices rename ID NAME` renames a device (on home only); `ID` is the
  device's id or 4 or more leading hex digits of it. Names are stored
  unencrypted in `vault.json`, at most 40 characters, cleaned as the vault
  label is, and covered by its tag and home's signature, so storage cannot
  rename a device. `--json`: the device as in `devices list`.

Device keys never leave the machine: there is no command to export them, and a
copied state directory makes two installs one device.

**New epochs** (`format.md` §15.14, design §5.2, §5.6, §6.3, §6.5). Removing a
device, handing the home role over, a takeover with the recovery key and
replacing the recovery kit each start a new epoch: a new vault key, an epoch
record in `epochs/` (written under its final name first) and a new `vault.json`,
under the vault's write lock. Files written before keep their key; the record
seals every file the machine holds that verifies, so every listed device keeps
reading them. From that moment every write is under the new key. A file written
later under an older key that no record seals (by a removed device, or by a
listed device that had not seen the change) is **set aside**: never read as a
note, never deleted. A machine that had not seen the change re-encrypts its own
such files (**catch-up**: its write ledger in `$XDG_STATE_HOME/sempere/ledger`
lists every file it wrote; the first write after it verifies the new epoch does
it, or `vault catch-up`). Revisions keep the machine's own id from
`device.json` in their names; its published summaries file and sync state use
its device id in the vault.

- `devices remove ID...` (home only, never itself) removes devices: for a store
  vault with sync targets it first pulls from each (design §5.2 step 2: a
  pull-only pass, at most 10 seconds each, that places what verifies, so the
  change seals it; an unreachable target is named on stderr, and the devices
  that wrote there catch their files up themselves; `--no-pull` skips it,
  `--password-env` names the variable holding the password of every WebDAV
  target of the vault: one variable for all of them), then catches up its own
  files, then starts the epoch. A removed device that last completed a two-way
  sync more than a day ago (or never, as far as its summaries file says) is
  named: changes it made since will not reach the vault. The removed machine gets
  exit 8 from then on (it still reads nothing new: the new key is not wrapped to
  it); over a sync it learns it at its next run. The change reaches the targets
  with the next sync. A key change cannot take storage access away: change the
  password of a WebDAV target the device used, or sign it out of iCloud.
  `--json`: `epoch`, `epochId`, `reason` (`remove`), `removed` (ids), `home`,
  `sealed` (files), `pulled` (`[{target, reached, downloaded, error}]`, store
  vaults) and `removedDevices` (`[{id, name, lastSynced, stale}]`).
- `devices status [--export DIR] [--forget-sightings [--all]]`: this machine's state in the vault: `listed`;
  `waiting` (a sync met a later device list it cannot verify yet: it writes
  here, uploads nothing new until it can, `format.md` §15.15); `record-pending`
  (it took a change whose record has not arrived: files from before it are not
  read yet); or `unlisted` (the newest list it verified does not hold it: it
  writes nothing, exit 8, and keeps pulling; a takeover that lists it again
  undoes that). It also lists this machine's own files (its write ledger) that
  no sync target of the store vault holds; `--export DIR` copies them as they
  are under their vault paths. It lists the sightings (device lists a sync met
  and this machine did not take, `format.md` §15.10): an anchored one holds
  every sync back; a detached one (nothing verifies it, so anyone with write
  access to a target can plant one) holds back only syncs with the targets
  that still show it and lapses once none does. `--forget-sightings` forgets
  the detached ones; `--all` also the anchored ones (with a warning: a removal
  marker among them, after which the machine writes and uploads again until a
  sync meets the change again). A sync held back for more than a day says since when. `--json`:
  `state`, `notice`, `heldSince`, `sightings` (`[{epoch, epochId, anchored,
  sources, seen}]`), `forgotten`, `unsynced`, `exported`.
- `devices handoff ID` (home only) makes another listed device home: an epoch
  with the same devices, signed by the old home. From then on only the new home
  approves, renames, removes or replaces the kit. It pulls from a store vault's
  targets first, as `remove` does (`--no-pull`). `--json`: as `remove`.
- `devices takeover --recovery-key FILE` (also `recovery takeover`) is for a lost or stolen home: the
  holder of the recovery key (the kit's identity file, or the vault's
  passphrase copy `keys/recovery-*.key.age`, which carries the root) makes this
  machine home under a `takeover` epoch signed by the recovery key and by this
  machine, whose parent is the epoch this machine pinned (a machine that never
  joined: the current one, checked against `--root`, the kit's 16 groups; a kit
  join). Without `--yes` it prints the devices to choose from (those of the
  current list, and those an earlier epoch removed, for example by a stolen
  home) and writes nothing (exit 2); `--keep ID` (repeat) or `--keep-listed`
  picks them. A takeover beats every epoch of the old home that is not its
  ancestor: devices that followed the stolen home's later epochs drop them and
  catch up their own files. Only the kit of the epoch this machine pinned takes
  over: a kit a replacement retired, or one this machine has not pinned yet, is
  refused (exit 1). A machine with no device key for the vault gets one (as
  `device init`, `--name`, `--kind`). The choices name the epochs above the
  parent that the takeover drops and the devices they removed; those are not
  kept by `--keep-listed` (name them with `--keep` if they should stay). Names come
  from this machine's trust record where it has them (a stolen home may have
  renamed devices). `--json` without `--yes`: `parentEpoch`, `choices`
  (`[{id, name, nameTrusted, listed, removedByDroppedEpoch, checkedByDefault}]`),
  `dropped` (`[{epoch, reason, author, removed}]`), `keep`; with it, as `remove`
  (`reason: takeover`). A listed machine taking over a store vault pulls from its
  targets first (`--no-pull`); the takeover reaches the targets with the next
  sync, and devices that followed the old home take it there (`format.md`
  §15.15).
- `recovery replace --recovery-out FILE` (home only) replaces the recovery kit
  after the device review: every listed device but this one must be named with
  `--keep ID` or `--remove ID` (devices a takeover added since the current kit
  are marked "TAKEOVER"). Without `--yes` it prints the review and writes nothing
  (exit 2); `--yes` confirms you are at the device (the app asks for Face ID or
  the passcode). The new key goes to `FILE` (mode 0600; print the kit with `keys
  paper --identity FILE`, then delete it); the epoch drops the old key and the
  removed devices, and from then on no machine that saw it takes a takeover by
  the old kit. `--old-recovery-key FILE` (the old kit or the passphrase copy)
  adds the old key's signature as evidence; `--recovery-passphrase` writes the
  passphrase copy for the new key and deletes the old copy (and a sync deletes
  the superseded copy from every target, `format.md` §15.15). With `--yes` it
  pulls from a store vault's targets first (`--no-pull`). `--json`: as
  `remove` (`reason: recovery`).
- `set-aside list` shows the files this machine set aside (SHA-256, vault path,
  reason: `not-sealed`, `bytes-differ` or `dropped`, and `superseded` when the
  vault holds the same body accepted); `export [SHA...] --to DIR` copies them
  as they are (age files) under their vault paths; `keep SHA... --yes` puts
  them back in the vault re-encrypted under the current key (they may come
  from a removed device: keep only what you recognize; refused when the path
  holds an accepted file with another body); `clear (SHA... |
  --superseded) --yes` deletes them from this machine. Items are named by their
  SHA-256 or 8 or more leading hex digits. The store is
  `$XDG_STATE_HOME/sempere/setaside/<vault id>/`.

### Vault

```
sempere vault init PATH (--recovery-out FILE | --recovery-key FILE) [--recovery-passphrase]
                        [--name TEXT] [--kind WORD] [--passphrase] [--passphrase-env VAR] [--vault-label TEXT]
sempere vault info
sempere vault label [TEXT | --clear] [--json]
sempere vault verify
sempere vault index [--out PATH|-]
sempere vault summaries [--out PATH|- | --device-file] [--plaintext] [--no-cache]
sempere vault merge-copy FROM [--dry-run] [--json]
sempere vault catch-up [--json]
sempere vault reencrypt --recovery-out FILE (--keep ID | --remove ID)... [--recovery-passphrase]
                        [--allow-unreachable TARGET]... [--no-pull] [--password-env VAR] [--yes] [--json]
sempere vault reencrypt --resume [--password-env VAR] [--json]
sempere vault reencrypt --status [--json]
```

- `reencrypt` (key-hierarchy design §7, `format.md` §15.16; on the home device) re-encrypts every file under a
  new vault key and a **new recovery key**: for a lost kit, when nothing on the storage should open with it any
  more. The device review comes first, as for `recovery replace` (every listed device but this one named with
  `--keep` or `--remove`; without `--yes` the review is printed, exit 2). Then a pull from the store vault's
  targets (unless `--no-pull`); every target must be reachable (`--allow-unreachable` lets one wait: the finish
  waits for it too); the journal claims every target (a target holding another re-encryption's journal refuses:
  nothing written, exit 1); the new recovery key goes to `--recovery-out` (mode 0600; print the kit with `keys
  paper`, then delete the file), and the `reencrypt` epoch starts. Then one step, which `--resume` repeats: the
  pass over this machine's files (each copy verified before the old one goes; files the acceptance rule does not
  take are set aside), a sync with every target, each target confirmed (files under earlier keys replaced or set
  aside and deleted there, old blob names and earlier epoch records deleted), and once all are, the finish and a
  sync with every target again. Exit 0 once finished, 1 while it is not (run `--resume` again; it also continues on
  a new home after a handoff, and cleans up a start that stopped before its epoch). `--status` reports and changes
  nothing. `--json`: `{epoch, pending, finished, remaining, total, reencrypted, left, problems, targets: [{name,
  reached, confirmed, files, current, replaced, deleted, waiting, error}], started, recoveryOut}`. A vault that is
  not a store vault has no targets here and finishes at once (its `sync folder` runs carry the new copies).

- `init` creates the vault (`PATH` must end in `.sempere`), with this machine
  as its home device: epoch 1 with a new vault key, its epoch record in
  `epochs/`, and `vault.json` listing this machine's new device key and the
  recovery key, each with a wrap of the vault key, signed by this machine
  (`format.md` §2). The device key and signing keys go to
  `$XDG_STATE_HOME/sempere/devices/<vault id>/device.key` (mode 0600; with
  `--passphrase`, passphrase-wrapped as `device.key.age`) and never leave the
  machine; `--name` and `--kind` describe it as for `device init`.
  The **recovery key** is either new, written to `--recovery-out FILE` (mode
  0600, refuses to overwrite), or the post-quantum identity `--recovery-key
  FILE` names; one of the two is required. No device keeps it: print the kit
  (`keys paper --vault PATH --identity FILE --out kit.pdf`), store it offline,
  and delete the file. `--recovery-passphrase` also writes the recovery key's
  **passphrase copy** into `keys/recovery-<fingerprint>.key.age` (scrypt work
  factor 20, with the vault id and root inside; `format.md` §3.2). That file
  is on the vault's storage, where its passphrase can be guessed offline, so a
  passphrase estimated below about 70 bits (`PassphraseStrength`: six random
  words, or a long random password, pass) is refused with exit 2, with no
  override. Passphrases come from the variable named by `--passphrase-env`,
  else `$SEMPERE_PASSPHRASE`, else the terminal (confirmed). A failed `init`
  removes the device key and recovery key file it wrote.
  Output: the path, the vault id, the root as 16 groups, this device's id and
  key file. `--json`: `path`, `vaultId`, `root`, `device`, `deviceKey`,
  `recoveryKey`, `passphraseCopy`.
- `init --vault-label TEXT` and `label TEXT` store the vault's display name,
  `vault.json`'s `label` (format.md §2), cleaned (one line, trimmed, at most
  80 characters, control characters replaced, invisible format characters
  such as bidi overrides and zero-width characters removed); `label --clear`
  removes it, and `label` alone prints it (nothing when there is none;
  `--json`: `{label}`, null when none). Reading needs no key; setting needs
  the key of a listed device whose list checks (not only home's: the label is
  covered by no signature), and writes the rest of `vault.json` back as it is.
  **The label is stored unencrypted in `vault.json`**: anyone with access to
  the folder or the server can read it, and anyone who can write there can
  change it, so put nothing private in it. It is for display only and never
  trusted: the app names a WebDAV vault by it in its lists (the server folder
  may be called anything), and nothing acts on it. Setting it refuses a
  `vault.json` that changed on disk since the vault was opened. A WebDAV copy
  gets it with the next sync.
- `info` prints the vault id, label (when there is one), creation time, root
  (16 groups), epoch, format, number of notes, the devices (id, kind, name,
  "manages devices" for home), whether a passphrase copy is in `keys/`, the
  join requests waiting, what it was opened with, and a `Device list:` line:
  `verified` (`first use on this machine` the first time), `not checked
  (locked)` without a key, or `REFUSED (reason): …; nothing is written to the
  vault`. It works without a key. `--json`: `path`, `vaultId`, `label`,
  `created`, `root`, `epoch`, `epochId`, `home` (the home device's id),
  `devices` (as in `devices list`), `notes`, `passphraseCopy`, `joinRequests`,
  `unlocked`, `openedWith`, `format`, `features`, `readOnly`,
  `readOnlyReasons` and `list`: `status` (`verified`, `refused`, or
  `not-checked`), for `verified` a `verification` (`unchanged`, `firstUse`,
  `added`: home approved devices since this machine's trust record, `renamed`,
  `newEpoch`: a removal, handoff, takeover or kit replacement since, whose
  chain this machine follows), for `refused` a `reason` (`listTag`,
  `markersTag`, `markersRolledBack`, `authorSig`, `epochSig` (also a chain of
  device changes that does not verify), `introducesDevice`, `addSig`,
  `rootMismatch`, `otherEpoch` (an epoch record that has not arrived, a chain
  this machine does not follow, or a takeover waiting for its kit to be
  pinned), `entriesChanged`, `recordUnreadable`, `rootUnconfirmed`) and a
  `detail`.
- **The device list is authenticated** (`format.md` §2.1, §15.3).
  `vault.json` carries `listTag` (an HMAC of the list under a key derived from
  the vault key), `markersTag` (the same over `format` and `features`) and the
  home device's signatures, so nobody without the key can add a device, and
  nobody but home can change the list. With a key, every command checks it
  against this machine's trust record (`$XDG_STATE_HOME/sempere/trust/<vault
  id>.json`, `sempere-trust/3`, mode 0600, kept by commands that write; it
  holds public keys only). A list that does not check is refused for writing
  with exit 6 (see Exit codes); reading still works. There is no repair
  command: put back the home device's `vault.json` (another copy, a backup).
- `verify` decrypts, tag-checks and decodes every file and prints
  `status  path` per file plus counts, a `MANIFEST` line per problem of
  `vault.json` (each wrap must be an armored age file with one stanza), and a
  `DEVICES` line (the device list, as in `info`). Every file must be encrypted
  to the vault identity in one stanza: one with other stanzas is
  `extraStanzas`. Exit 0 only if the vault is healthy, 6 when `vault.json`
  does not check on this machine (including a join not confirmed yet), else
  3. It works with the recovery key (`--recovery-key FILE --root HEX`,
  read-only). `-q` lists only the problem files (the healthy `unreferenced`,
  `unknownFile`, `notChecked`, `newer`, `setAside` and `pending` are not
  listed). Above epoch 1 a file under an earlier key is `ok` when the record
  that closed its epoch seals it, `setAside` when not (healthy: never read as
  a note; see Devices, "New epochs"), and `pending` when that record has not
  arrived. `--json` emits
  `healthy`, `manifestProblems`, `counts`, `files` (`{path, status,
  detail}`), `readOnly`, `readOnlyReasons` and `list` (as in `info`).
  Attachment blobs are decrypted and hashed in full: `ok`, `unreferenced`
  (healthy: no revision of its note uses it; `blobs gc` removes it later),
  `invalid` (bad framing, padding, hash or name), `extraStanzas`, and a
  `missing` line for each reference with no blob.
  Voice notes waiting in `inbox/` (`format.md` §11.2) are decrypted and
  tag-checked under the capture keys as adoption does: `ok`, `invalid` (fails
  to verify: never adopted), `extraStanzas`, or `notChecked` when the
  device list does not check; other names there are `unknownFile`. The epoch
  record named by `vault.json` must hash to `epochRecordHash`, open under the
  key and carry a chain from the vault's root ending at this epoch (`ok` or
  `invalid`); earlier epochs' records of that chain are `ok`, other names in
  `epochs/` (an orphan record of a change that crashed) are `unknownFile`. Join requests in
  `joins/` are `ok` when they parse and name this vault under their own name,
  else `invalid`. In `keys/`, only the passphrase copy's name is expected
  (it is not decrypted: that needs its passphrase).
- `catch-up` re-encrypts under the current key the files this machine wrote
  under an earlier key that no device change sealed (its write ledger,
  `$XDG_STATE_HOME/sempere/ledger/<key>/<vault id>/`, one per device key, sealed to it), each
  verified and its old bytes set aside before it replaces them, and copies
  every other unsealed file under an earlier key into the set-aside store. The
  first write after this machine verifies a new epoch does it by itself; the
  command reports. Exit 1 when a file could not be caught up (tried again by
  the next writer). `--json`: `reencrypted`, `pruned`, `sealedKept`, `dropped`,
  `setAside`, `problems`.
- `index` writes `sempere-index.json` at the vault root (or `--out PATH`;
  `--out -` prints it): every note id and its revision file names, the
  listing the web viewer reads on a static server that cannot list folders
  (`docs/web-viewer.md` "Hosting"). It needs no key and holds only names that
  storage already shows; with a key, the usual write checks apply. Once it exists it is kept current automatically:
  every command that opens the vault rewrites it when the listing changed (a
  failure to do so is a warning), and `sync webdav` rewrites the server's
  copy when the server has one. A WebDAV share needs no index. `--json` emits `path`, `notes` and `revisions`.
- `summaries` writes `sempere-summaries.sealed` at the vault root (or `--out
  PATH`; `--out -` prints it): the published note summaries of `format.md`
  §12, which the web viewer lists and searches a vault from without decrypting
  every revision (`docs/web-viewer.md` "Opening fast"). Per note: title, tags,
  notebook, favorite and deleted flags, created and modified dates, page count
  and each page's searchable text, with the revision file names it was made
  from; notes with an unreadable revision get no entry. Sealed with AES-256-GCM
  under a key derived from the vault key, so it needs the key (exit 4
  without it) and only the vault's keys open it. Entries of an existing file
  whose notes did not change are reused (others go through the summary cache
  unless `--no-cache`), so a rerun reads only changed notes. Once it exists it
  is kept current: every command that unlocks the vault rewrites it when a
  note changed (a failure is a warning); commands without the key leave it
  alone, so it may lag until the next one. `--plaintext` writes the JSON
  content instead, in the clear (for checks and the web goldens); it needs
  `--out`, so it never lands at the vault's sealed path by default, and a
  file it writes is readable by its owner only (created 0600 next to the
  target, then renamed over it). `--json` emits `path`, `notes`, `entries`,
  `read` (notes summarized again) and `bytes`. `--device-file` writes this
  device's own copy instead, `summaries/<device>.sealed` (`format.md` §12.5,
  the device's id in the vault), naming that device, under the next version
  (one more than the file there, at least the clock in milliseconds) and
  signed with the device's signing keys (from its device key file; a key
  without them cannot write it): the per-device files the apps publish so
  that another device lists a vault's notes before they arrive.
- `merge-copy FROM` merges another copy of the same vault into the vault
  (`format.md` §1.3): the losing side of an iCloud Drive conflict, a copy taken
  from another device, a folder restored from a backup. Every revision, blob,
  inbox file, epoch record, join request and passphrase copy the vault lacks
  is checked as a received file
  (`format.md` §9.1: with the key, decrypted and verified; without it, its age
  structure) and copied in; `settings.age` is merged per key (§13.3), which
  needs the key (locked, it is reported as pending). `vault.json` is taken
  from `FROM` only when it is a later version of the vault's own by its home
  device (the same epoch, every check passing, its list holding this one's:
  a device approved or renamed since; needs the key); otherwise a difference
  is only reported, and a difference in `label` alone is none. Nothing in the
  vault is deleted, so a second run
  does nothing; a file both copies hold with different bytes keeps the vault's
  and is listed. `FROM` must hold a `vault.json` of the same vault id (else exit
  1). Lines: `added PATH` (`would add` with `--dry-run`), `refused PATH: why`,
  `differs PATH`, then the settings and manifest notes (`took vault.json (a
  later version)` or `vault.json differs (kept the vault's)`). Exit 1 when a file was
  refused. `--json` emits `added`, `differing`, `refused` (path → why),
  `settingsMerged`, `settingsPending`, `manifestUpdated` and `manifestDiffers`.

**Removed with the key hierarchy** (no migration; vaults of the earlier
format, with a recipients list and a vault secret, are not read): `vault
recipients add|remove|replace|repair|confirm`, `vault markers`, `vault
rewrap-resume`, `vault rewrap-discard`, `keys export`, and `vault init`'s
`--recipient`, `--label`, `--store-key` and `--allow-weak-passphrase`. Adding a device is `device init` and `devices
approve`; removing one is `devices remove`, and replacing the recovery key `recovery replace` (Devices, "New
epochs"); re-encrypting everything comes with phase KH6 of the key hierarchy (`docs/design/key-hierarchy.md` §12).

### Vault store

```
sempere store list [--store DIR] [--json]
sempere store path VAULT [--store DIR] [--json]
sempere store create NAME (--recovery-out FILE | --recovery-key FILE) [vault init's options] [--store DIR] [--json]
sempere store import SOURCE [--name NAME] [--keep-syncing] [--store DIR] [--json]
sempere store restore BACKUP [--name NAME] [--replace] [--store DIR] [--json]
sempere store remove VAULT --yes [--store DIR] [--json]
sempere store target list VAULT [--store DIR] [--json]
sempere store target add VAULT (--folder PATH | --webdav URL [--user NAME] [--password-env VAR | --no-check])
                         [--name NAME] [--store DIR] [--json]
sempere store target remove VAULT TARGET [--store DIR] [--json]
sempere store sync VAULT [--target TARGET ...] [--identity FILE | --passphrase-env VAR] [--password-env VAR]
                         [--wait SECONDS] [--store DIR] [--json]
sempere store info VAULT [--measure-folders] [--store DIR] [--json]
sempere store quarantine list VAULT [--target TARGET] [--store DIR] [--json]
sempere store quarantine adopt VAULT PATH... [--target TARGET] [--identity FILE | --passphrase-env VAR] [--store DIR] [--json]
sempere store quarantine export VAULT PATH... --to DIR [--target TARGET] [--store DIR] [--json]
sempere store quarantine delete VAULT PATH... [--target TARGET] [--store DIR]
```

A store is a folder of complete vaults, one per vault id, laid out as `<store>/<vault id>/<name>.sempere`
([device-first sync](design/device-first-sync.md) §2). The app keeps every vault in its own store, hidden
in its container (on a Mac:
`~/Library/Containers/io.github.anthonytw.sempere/Data/Library/Application Support/Sempere/Vaults`); these
commands work on that store or any other. `--store DIR` names the store; the default is `$SEMPERE_STORE`,
else `$XDG_DATA_HOME/sempere/vaults` (`~/.local/share/sempere/vaults`). `VAULT` is the vault id, a unique
prefix of it (4 characters or more), or the vault's exact name. Every other command reaches a store vault
by its folder: `--vault "$(sempere store path Notes)"`.

- `list` prints name, id, label and path of every vault (reading only each `vault.json`, no key); a vault
  whose `vault.json` does not open or names another id is listed with a warning on stderr. `--json`: an
  array of `{vaultId, name, path, label, problem}`.
- `path` prints the vault's folder (`--json`: the same object).
- `create NAME` makes a new vault in the store, with `vault init`'s options (`--recovery-out` or
  `--recovery-key`, `--name`, `--vault-label`, `--recovery-passphrase`, …; [Vault](#vault)): this machine is its home. `NAME` is the folder name without `.sempere`: no
  slashes, colons, leading dots or control characters (exit 2). Names need not be unique; ids are.
- `import SOURCE` copies the vault folder `SOURCE` into the store, as the app's Open Vault… does. The
  source is only read. It must be a complete vault: a readable `vault.json`, no partial-copy markers
  (format.md §1.2), no unfinished restore, no cloud placeholders (`.<name>.icloud`: download it first), and
  only folders and regular files (a symbolic link or special file is refused). Hidden files (`.DS_Store`,
  temporary files) are not copied. Every file is copied and read back, then the whole copy is compared byte
  for byte with the source and the source is listed again; only then does the vault appear in the store,
  moved there in one rename. Any failure, or an interruption, leaves nothing listed (what it left in the
  store's staging folder is removed by the next store command). A vault id the store already holds is
  refused (exit 1). `--name` names the copy (default: the source folder's name); `-q` prints only the new
  path; `-v` reports progress on stderr. `--keep-syncing` makes the source a folder target of the copy (the
  app's "Keep syncing with this folder"): `store sync` then syncs the two both ways.
- `restore BACKUP` restores a backup folder (or any vault folder) into the store, every file checked
  against `backup.json` as `sempere restore` does. The restore is built in the store's staging folder and
  must bring back every file, else nothing is added (exit 1). A vault id the store already holds is
  refused unless `--replace`: then the store's copy is replaced as a whole once the restored one is
  complete, keeping its name (changes made since the backup are lost), and only while that vault is not
  open. The old copy is moved aside before the new one moves in and deleted after; a crash between the two
  leaves it aside, and the next store command puts it back. `--name` names a new vault (default: the
  backup folder's name). `--json`: `{vault, restored}`.
- `remove VAULT --yes` deletes the vault from the store, permanently: with no other copy, its notes are
  gone. Without `--yes` it exits 2 and deletes nothing. It is refused (exit 1) while the vault is open in
  the app or by another command, which hold a lease on it.

#### Sync targets

A store vault may have any number of sync targets, outside copies it syncs with both ways
([device-first sync](design/device-first-sync.md) §2, §8.1): a **folder** (iCloud Drive or another
provider's folder, a drive, a share, any folder) or a **WebDAV** server folder. They are kept in
`<store>/.sync/<vault id>/targets.json`, which the app reads and writes too (its folder targets also carry
a bookmark), and each target's sync state, quarantine and transfers in `<store>/.sync/<vault id>/<target
id>/`, so targets and vaults never share state. Removing the vault removes them. `TARGET` is a target's id,
a unique id prefix (4 characters or more), its name, path or URL.

- `target list` prints id, kind, name, place and the last successful sync. `--json`: an array of `{id,
  kind, name, path, url, user, added, lastSuccess}`.
- `target add` adds a target. `--folder PATH` may be missing or empty (the first sync copies the vault into
  it) or hold the same vault (the first sync is a union: what either side lacks is copied, nothing is
  deleted); it must not overlap the store and must not be a file (exit 1). `--webdav URL [--user NAME]`: https,
  or http to localhost (exit 2 otherwise); no password is stored. A target at the same place (the same
  folder, or the same server folder and user) is refused (exit 1). `--json` prints the new target; `-q` only
  its id. A WebDAV target's server folder is listed first, with the password from `--password-env`
  (default `SEMPERE_WEBDAV_PASSWORD`, needed with `--user`), and one that holds another vault or other files
  is refused (exit 1): it must be empty, missing (the first sync creates it) or hold this vault
  (`WebDAVConnection.checkTargetFolder`, which the app's Add WebDAV Server… runs too). `--no-check` adds it
  without contacting the server.
- `target remove` forgets a target and deletes its sync state on this machine; the folder or server is not
  touched.
- `sync` runs the vault with each target in turn (or only the `--target` ones): the two-way sync of
  `sync folder` or `sync webdav` (every rule there applies), each with its own state and quarantine, under the
  vault's write lock. Unlocked (`--identity`, or the stored key's passphrase), received files are checked
  fully and explained deletions follow; locked, only their structure is checked and nothing is deleted. A
  machine with two targets bridges them: what one brings goes to the other on the next run. A folder target
  synced before that is gone is not recreated ("the folder is gone"), and one whose parent folder is gone (a
  drive not connected) is skipped ("cannot be reached now"); both are errors of that target only. WebDAV
  passwords come from `--password-env` (default `SEMPERE_WEBDAV_PASSWORD`); `--wait` bounds the wait for
  files a provider is downloading (default 30 s). `--json`: an array of `{target, kind, name, report,
  error}`, `report` being `sync folder`'s object. Exit 1 when a target could not run, else `sync folder`'s
  codes, the worst first. A target kind a later version added is reported, never run.
- `info` (the app's Vault Details, [device-first sync](design/device-first-sync.md) §8.3, §8.4) reads this
  machine only, never a target: the vault folder's sizes (notes, attachments, other files) and, per target,
  its last sync, the files both sides had then, the files staged for the next unlock, the bytes of its
  state folder and (`--measure-folders`) of a folder target's copy, its quarantined files, and the devices
  whose revisions or `summaries/<device>.sealed` it held at the last sync, named from the vault's device list
  (`vault.json`, read without the key; none for a device it does not list), with their revision count and
  newest revision's clock. A device of the vault missing from a target never syncs with it (an island, §5.6).
  `--json`: `{vault, name, storage: {notes, attachments, other}, targets: [{target, syncedFiles, devices:
  [{device, name, revisions, newest, publishesSummaries, isThisDevice}], quarantined, staged, stateBytes,
  folderBytes}]}`.
- `quarantine` works on the files sync runs refused (format.md §9.1), kept per target and never removed
  by a run (the app's Repair). `list` prints each with its target, path in the quarantine, size, date and
  whether it can be adopted (`--json`: `[{target, file: {path, vaultPath, size, quarantined, adoptable}}]`).
  `adopt PATH...` needs the key: each file is checked again under the vault's current keys by a pull-only
  run from a scratch folder holding only the vault's root files and that file, and placed only if it
  passes, then removed from the quarantine; one the vault already holds with the same bytes is just
  removed; one that still fails, or a root file (`vault.json`, settings: they arrive only through a sync
  run), stays (exit 1, the reason printed; `--json`: `[{path, adopted, error}]`). `export PATH... --to DIR`
  copies files out, never over a file there (`" 2"`, `" 3"`… added); they stay. `delete PATH...` removes
  them for good. A path held by several targets' quarantines needs `--target`.

Each vault has its own lock (`<store>/.locks/<vault id>.write`, `flock(2)`): the store takes it to install
or remove a vault, and it is the one lock every writer of that vault on the device shares
([device-first sync](design/device-first-sync.md) §4), so writers of two vaults never wait for each other.

### Attachments

```
sempere blobs list [NOTE ...]
sempere blobs verify [NOTE ...]
sempere blobs extract NOTE SHA256 [--out FILE]
sempere blobs add NOTE FILE --type MEDIA/TYPE
sempere blobs copy SHA256 --from NOTE --to NOTE
sempere blobs unused [NOTE ...] [--retention DAYS] [--no-cache]
sempere blobs gc [NOTE ...] [--dry-run] [--retention DAYS] [--file NAME ...] [--no-cache]
sempere blobs repair [NOTE ...]
```

Blobs hold the bytes of images, PDFs, video clips and their posters,
recordings and transcripts, one
encrypted file per content per note: `notes/<id>/att/<keyed hash>.<kind>.age`
(`format.md` §8.1). Revisions reference them by SHA-256; a note never uses
another note's blobs. NOTE is an id or a title; without one, every note.

- `list` shows each blob (kind, size on disk, referenced or not) and every
  reference with no blob (`MISSING`), unreadable revisions and unknown files.
  It reads the revisions but decrypts no blob.
- `verify` decrypts and checks every blob of the notes (as `vault verify`
  does, restricted to blobs). Exit 3 unless every blob is `ok` or
  `unreferenced`.
- `extract` writes the verified content of the blob a revision of NOTE
  references (SHA256, or a unique prefix of at least 8 digits). With `--out`
  the file appears only once the whole content has verified and is never
  overwritten; on standard output content streams as it is decrypted, so on
  an error (exit 1) discard what was printed.
- `add` stores a file as a blob of NOTE (streaming, any size up to 1 GiB) and
  prints the reference to put in a revision (`{"sha256", "size", "type"}`;
  `-q` prints only the hash). It adds no item; until a revision references
  the blob it is unreferenced.
- `copy` copies a blob that NOTE `--from` references (SHA256, or a unique
  prefix of at least 8 digits) into NOTE `--to` (a byte copy, verified as it
  is read), before a revision there uses it.
- `unused` shows what the app's Settings ▸ Storage shows, from the same code
  (`AttachmentStorageReport`, `docs/attachments.md` §4): blobs no revision of
  their note references, each with the date this device first found it
  unused, the date it may be deleted (that plus `--retention` days) and
  whether it may be deleted now; and the blobs only older revisions use
  ("held by history", freed when compaction drops those revisions). Text:
  one row per blob and the line `Unused attachments: N item(s), X (M
  deletable now, Y); held by history: K item(s), Z`. `--json` emits
  `retentionDays`, the totals `unused`, `eligible` and `heldByHistory`
  (`{count, bytes}`), `items` (`note`, `title`, `file`, `kind`, `bytes`,
  `firstSeen`, `deletableFrom`, `eligible`, `lastUse`: the newest revision
  that used it, with its `wall` and a recording's `duration` and `title`),
  `held` (`note`, `title`, `file`, `kind`, `bytes`, `sha256`, `revisions`)
  and `unchecked` (note → why nothing could be decided: an unreadable
  revision, a note not fully downloaded). Read only: the dates come from this device's
  record without updating it, so a blob never seen before shows today. Exit 3
  when a note could not be checked. The app keeps its own record, so the
  dates can differ between the app and the CLI on one Mac.
- `gc` deletes those that have been unreferenced for `--retention` days
  (default 30), per `format.md` §8.1.6: per note, only when every revision of
  the note was read and verified, no revision
  (deleted notes and old restore points included) references the blob, and
  this device first found it so at least the window ago. The first sighting
  is recorded in `$XDG_STATE_HOME/sempere/blobs/<vaultId>.json` (default
  `~/.local/state/...`), never in the vault; a blob that becomes referenced
  again loses its record. `--file NAME` (repeatable) deletes only those blob
  files, as the app's per-item Delete does; the window still applies. After
  collecting it prints the `unused` line (`--json`: `{"notes": [...],
  "storage": <as unused>}`). A blob is decrypted and verified in full before it
  is deleted; one that cannot be is reported and kept. `--dry-run` deletes
  and records nothing. Exit 3 when a note could not be collected (unreadable
  revision, a note not fully downloaded) or a blob could not be verified.
  Collection never happens as a side effect of `compact`, `sync` or opening.
- `repair` fixes blobs that do not match the vault's key or their references
  (named under another key, encrypted with other stanzas than the one to the
  vault identity, or under the wrong kind): each is verified, re-encrypted to
  the vault identity and renamed. Only authentic blobs are touched (the name
  verifies under the current key, or a verified revision of the note
  references the content); anything else is listed and left alone (exit 3).

`recover` also reads a single blob file without the vault (see "Recover").

#### Adding attachments

```
sempere attach image NOTE FILE [--page N] [--frame X,Y,W,H | --at X,Y [--width W]] [--crop X,Y,W,H]
                               [--rotation DEG] [--layer content|background] [--keep-metadata]
                               [--rec RECORDING [--rec-at SECONDS]] [--dry-run]
sempere attach pdf NOTE FILE [--pages 1-3,5,7-] [--after N] [--pdf-text auto|builtin|poppler|none]
                             [--page N [--frame ... | --at ... --width ...] [--crop X,Y,W,H]] [--dry-run]
sempere attach text NOTE (TEXT | --file FILE|-) [--page N] [--frame ... | --at ... --width ...]
                             [--font sans|serif|mono] [--size PT] [--color #RRGGBB[AA]]
                             [--align start|center|end|left|right] [--bold] [--italic] [--lang TAG]
                             [--markdown] [--no-breaks]
                             [--layer content|background] [--rec RECORDING [--rec-at SECONDS]] [--dry-run]
sempere attach math NOTE (--latex SOURCE | --latex-file FILE|-) [--page N] [--frame ... | --at ... --width ...]
                             [--inline] [--size PT] [--color #RRGGBB[AA]] [--render FILE.pdf [--engine NAME]]
                             [--layer content|background] [--rec RECORDING [--rec-at SECONDS]] [--dry-run]
sempere attach video NOTE FILE [--page N] [--frame ... | --at ... --width ...] [--rotation DEG]
                             [--poster IMAGE | --poster-time S | --no-poster] [--keep-metadata]
                             [--layer content|background] [--rec RECORDING [--rec-at SECONDS]] [--dry-run]
sempere attach recording NOTE FILE [--title T] [--started TIME] [--type MEDIA/TYPE] [--duration S]
                             [--codec NAME] [--sample-rate HZ] [--channels N] [--bit-rate BPS]
                             [--place] [--page N] [--frame X,Y,W,H | --at X,Y [--width W]]
sempere attach transcript NOTE RECORDING FILE [--dry-run]
```

The commands the app's add flows have, scriptable (`docs/attachments.md` §14). Each stores the file's bytes as an encrypted blob of the note
(`blobs add` does the same without a placement), then writes **one delta**
through the same `NoteOps` the app uses, with this machine's device id and
clock (as `snapshot`). NOTE is an id, an id prefix or an exact title; a
deleted note is refused. Pages are numbered from 1 as `pages list` prints
them (`--page` defaults to 1); coordinates are points from the page's top-left.
Standard output is the new item's (or recording's) id, one per line, so
`ID=$(sempere attach image …)` works; the confirmation goes to standard error
(`-q` silences it). `--json` prints `{note, file, dryRun, blob, items,
recording, pagesAdded}`: `file` is the delta written (absent with `--dry-run`),
`blob` the reference stored (`sha256`, `size`, `type`), `items` the added items
as `notes show --json` prints them (`{page, pageId, item}`), `recording` the
recording added or changed; `pdf` adds `pagesWithText` and `textEngine`. `--dry-run` checks the file and the placement and
says what would be added; it writes neither the blob nor a delta. A blob
stored before a failing delta is unreferenced; `blobs gc` collects it. Nothing
is stored when the file or the placement is refused (exit 1; bad options are
exit 2).

- `image` takes a JPEG or PNG. The stored bytes have location and camera
  metadata removed (every APPn segment but JFIF, ICC and Adobe, and comments,
  in a JPEG; ancillary chunks but the color ones in a PNG) unless
  `--keep-metadata`; a JPEG's EXIF orientation is first copied to the item's
  `orientation`, so it still shows upright (`format.md` §8.2.5). HEIC, WebP,
  GIF, TIFF and CMYK or arithmetic-coded JPEGs are refused: convert them first.
  The file must decode, stay under 100 megapixels and 64 MiB. Without a frame
  the image is shown at one pixel per point, shrunk to fit inside a 36 pt
  margin, centered across the page and a margin from its top, moved down below
  any item it would cover (`NoteOps.unoccupied`: background items do not count,
  and on a page too short for that it stays at the top); `--at` and
  `--width` set its corner and width (the height follows the aspect of the image
  or its `--crop`, given in oriented pixels), `--frame` all four numbers.
  `--rotation` is degrees clockwise. Items stack in the order they are added
  (each gets a `z` above the layer's others); `--layer background` puts the image
  under the page's other items.
- `math` adds an equation (`format.md` §8.2.8): LaTeX in math mode without
  `$` delimiters, from `--latex` or `--latex-file` (`-` is standard input; one
  trailing newline is dropped), stored as NFC, display style unless
  `--inline`, `--size` 20 and black by default. The source is refused (exit 1,
  nothing written) beyond 8 192 bytes, with an unbalanced group (`{…}`,
  `\left…\right`, `\begin…\end`), more than 4 096 symbols or nesting deeper
  than 64 levels (`MathSource.check`). **The CLI has no math typesetter**
  (`Sources/` stays pure Swift): without `--render` the item has no rendering,
  its frame is estimated from the source (0.6 em per character of the longest
  line, 1.6 em per line, within the margins), exports draw the source in a
  monospace font and say so on stderr, and the app typesets it the next time
  the equation is edited there. `--render` stores a one-page, unencrypted PDF of
  the typeset equation made elsewhere (for example `pdflatex` on a `standalone`
  document, or `tectonic`, then `pdfcrop`) as its rendering, drawn only in the
  equation's color on a transparent page; the frame is then the PDF's page
  size (`--width` scales it, keeping the aspect), and `--engine` records what
  made it. The equation is searchable (`sempere search`), and Markdown and HTML
  exports keep its source as `$$…$$` (display) or `$…$` (inline). `items math`
  changes it later.
- `pdf` stores the PDF once and places pages of it (`--pages`, default all;
  the list keeps its order). By default each selected page becomes a **new note
  page** with the PDF page as a background that fills it (layer 0; fitted and
  centered when its size differs from the note's page size), inserted after note
  page `--after` (0: before the first; default the end), all in one delta.
  The note's page size is not changed, and a pageless note takes no inserted pages.
  With `--page` (and `--frame`, or `--at` and `--width`, and `--crop` on the
  effective page) **one** PDF page is instead placed as a figure on an existing
  page, in the content layer; `--pages` must then select exactly one. Encrypted
  PDFs, files that are not PDFs, PDFs with more than 2 000 pages or a page
  without a usable size are refused. Annotations and form fields are not drawn
  (`format.md` §8.2.6). `--pdf-text` (default `auto`) stores each PDF page's text
  for search: `pdftotext` when installed (`$SEMPERE_PDFTOTEXT`), else the built-in
  reader; `builtin`, `poppler` force one, `none` stores none.
- `text` adds a text box. The text is the argument, or `--file` (`-` is standard
  input), at most 65 536 bytes of UTF-8, stored as NFC with `\n` line breaks in
  one style (one trailing newline of a file is dropped). Without a frame the box
  is as wide as the page inside a 36 pt margin (or `--width`), a margin from
  the top and left (or `--at`). The text is laid out with the fonts `export`
  uses (bundled Noto and font packs) and the soft line breaks are **stored**
  (`breaks`, `format.md` §8.2.4, §8.5.3), so the app, the app's exports and
  `sempere export` break it into the same lines; without `--frame` the box is
  as tall as those lines at 1.2 × `--size` (default 14), a `--frame` keeps its
  height. `--no-breaks` stores none (each renderer then wraps the text with its
  own fonts); without usable fonts the CLI warns and stores none. `--lang`
  picks fonts for CJK text. Typed text is searchable (`search`).
- `video` places a video clip (`format.md` §8.2.7): an MP4 or QuickTime file
  (`.mp4`, `.m4v`, `.mov`) with an H.264 or HEVC video track, at most 1 GiB,
  stored as it is (no transcoding) and **streamed**: the file is read twice
  (hash, then encrypt) in 1 MiB pieces and never held in memory, so a 1 GiB
  clip takes a few MiB. Its container is read in pure Swift (`VideoProbe`:
  box headers and a few small boxes only; damaged or hostile files are refused
  with a typed error) for the duration, the display size (`pixelSize`, after
  the track's rotation) and the rotation (`videoRotation`). Unless
  `--keep-metadata`, the location and device metadata (every `udta` and `meta`
  box in `moov` or a track, a top-level `meta` and XMP `uuid` boxes: GPS
  position, make, model, software) are blanked
  **in place** on the way into the blob (type `free`, contents zero): the file
  keeps its length and every sample offset, so it plays unchanged; the file on
  disk is not changed. Other codecs (MPEG-4 Part 2, VP9, AV1), WebM, AVI and
  fragmented MP4 are refused: convert first (`ffmpeg -i IN -c:v libx264 -c:a
  aac OUT.mp4`, or `-c copy` to defragment). The poster frame is what exports
  and readers that do not play video draw: `--poster IMAGE` (JPEG or PNG,
  stored upright without metadata; an image with an EXIF rotation is refused),
  else on macOS a frame taken from the clip with AVFoundation
  (`--poster-time`, default 0.5 s, upright, at most 1920 px), else (Linux, or
  `--no-poster`) none: renderers draw a crossed box with a play mark, and
  `items poster` can add one later. Without a frame the clip is fitted inside
  the margins at most 480 pt wide, centered across the page, a margin from the
  top, below any item it would cover (as for `image`); `--at`, `--width`, `--frame`, `--rotation`, `--layer` and `--rec` as
  for `image`. Blobs are written poster first, then clip, then the delta.
  `--json` adds `poster` (the poster's reference) and `metadataRemoved` (the
  number of boxes blanked). `--dry-run` probes and hashes the clip (streamed)
  and writes nothing.
- `recording` stores an audio file and adds it to the note. MPEG-4 audio (`.m4a`;
  AAC-LC, HE-AAC or ALAC, `audio/mp4`) is read for its duration, codec, sample
  rate, channels and average bit rate; each option overrides what was read.
  Another format needs `--type audio/…` (stored and listed, perhaps not playable
  in the app). `--started` is the wall time of the first sample (RFC 3339);
  without it the file's modification time minus its duration. At most 1 000
  recordings per note. `--place` (or any of `--page`, `--frame`, `--at`,
  `--width`) also puts it on a page as an **audio item** (`format.md` §8.2.9)
  in the same delta, as the app does when a recording stops: a 300 × 96 point
  card (narrower on a narrow page), centered across the page a margin from its
  top and below any item it would cover (as for `image`), above the page's other items; standard output is then the item's id,
  then the recording's, and `--json` lists the item in `items`. `recordings
  place` places one later. `--rec ID` on `image`, `text`, `math` and `video` links an item to a
  recording (id, id prefix of 4+ characters or exact title) at `--rec-at` seconds
  (`format.md` §8.3.3).
- `transcript` sets a recording's transcript from a `sempere-transcript/1` JSON
  file (`format.md` §8.3.2). The file is checked (format, segment order and
  times, confidences, and that it names the recording by id); it replaces any
  transcript the recording has, in one `setRecording` delta.


#### Recordings

```
sempere recordings list NOTE
sempere recordings place NOTE RECORDING [--page N] [--frame X,Y,W,H | --at X,Y [--width W]] [--dry-run]
sempere recordings rename NOTE RECORDING TITLE
sempere recordings delete NOTE RECORDING
```

A recording belongs to its note (`format.md` §8.3); an **audio item** shows it
on a page (§8.2.9), where the app plays it from a card with its title,
length and transcript. RECORDING is an id, an id prefix of at least 4
characters or an exact title. Each change is one delta through the same
`NoteOps` the app uses.

- `list` prints each recording's start, length, title, whether it has a
  transcript and the pages that show it (`p1,p3`; `-` when it is on no page),
  and warns about audio items whose recording is missing. `--json`:
  `{recordings: [{recording, items: [{page, pageId, item}]}], missing: [...]}`.
- `place` adds an audio item for the recording (`addItem`): a 300 × 96 point
  card centered across page 1 (or `--page`) a margin from its top and below
  any item it would cover (a second placement goes under the first), or at
  `--at`/`--width`, or `--frame`. A recording may be placed any number of
  times. Output as for `attach` (the new item's id; `--json` the `attach` form).
- `rename` sets the title (`setRecording`); an empty title clears it.
- `delete` removes the recording and, in the same delta, every audio item
  that shows it (`NoteOps.removeRecording`). To take a recording off a page
  but keep it, delete its audio item with `items delete`. The audio and
  transcript blobs stay until `blobs gc`.

Exports draw an audio item as its card (`format.md` §8.2.9: the microphone
icon, the title and length, and the start of the transcript, cut at the
card's bottom); one whose recording is missing is a placeholder, reported as
"recording missing". `--recordings attach` embeds each recording once,
however many cards show it.

### Backup and restore

```
sempere backup [V] --to DIR [--prune] [--checksum]
sempere backup [V] --archive FILE.tar
sempere backup verify DIR [--identity FILE]
sempere backup status DIR [--max-age DAYS]
sempere restore DIR --to NEWPATH.sempere [--identity FILE] [--dry-run]
```

`V` is the vault (else `--vault` / `$SEMPERE_VAULT`). Backups only ever hold
the encrypted files: nothing is decrypted to disk, and no key is needed except
for `--prune` and for a full `verify`.

- `backup V --to DIR` keeps `DIR` an up-to-date copy of the vault. `DIR` is
  created if needed; an existing `DIR` must be a backup of the same vault (or
  empty). Every file is written atomically (temporary file in the same
  directory, `fsync`, rename) and read back to compare its SHA-256 with the
  source. Revision files are write-once, so a later run copies only new ones
  and skips a file whose size and recorded hash already match (`--checksum`
  re-hashes them all). That size shortcut is switched off for a run whenever
  the vault's `vault.json` differs from the backed-up one or a
  re-encryption journal (`reencrypt-journal.age`, `format.md` §15.8; key
  hierarchy KH6) exists on either side, because re-encrypting the vault
  rewrites files without changing their size; then every file is compared by
  hash. A file whose content changed (`vault.json`, `settings.age`, the
  journal) is replaced and its previous copy kept under
  `DIR/versions/<UTC time>/<path>`; a journal the vault no longer has moves
  there too. The epoch records (`epochs/`) and the passphrase copy (`keys/`)
  are copied like revisions. Nothing else is ever
  deleted: revisions the vault no longer has (compaction) stay, unless
  `--prune`, which deletes only those that a snapshot covers that the vault
  and the backup hold byte for byte identically (checked on disk, not from
  the index; the rules of `docs/format.md` §5.3, as `sync` applies them). A file lost from the vault without a covering snapshot is
  never pruned, and neither is an attachment blob
  (`notes/<id>/att/`, `format.md` §8.1.6: collection is per device, so a
  backup keeps every blob it has seen). `--prune` needs the key (exit 4
  without). An interrupted run
  (crash, full disk, Ctrl-C) leaves only complete files; running it again
  finishes the job and removes leftover temporary files. A full disk fails
  each file that does not fit (`errors`, exit 1) and the run never counts as
  completed (`backup status`). If `DIR` disappears during a run (a drive
  unplugged, a share disconnected: its `backup.json` is gone) the run stops
  with an error instead of recreating `DIR` and writing a partial backup there.
  `DIR` is itself a vault (`sempere --vault DIR` reads it) plus
  `DIR/backup.json` (vault id, and SHA-256 and size of every file the backup
  wrote) and `DIR/versions/`. Output: `copied`, `replaced` and `pruned` lines
  and a count line (`-v` adds versioned and kept files). `--json` emits
  `vaultId`, `destination`, `copied`, `replaced`, `versioned`, `unchanged`,
  `pruned`, `kept` and `errors` (`{path, message}`). One failing file does not
  stop the run. Exit 0 ok, 1 some files failed, 2 usage, 4 `--prune` without a key.
  `DIR` may live on storage others can write to, so no symbolic link in it is
  followed: a file that is a link is reported and replaced by the vault's
  copy (never read, hashed or kept under `versions/`), and a file reached
  through a linked folder is reported and skipped.
- `backup V --archive FILE.tar` writes one uncompressed POSIX tar of the
  encrypted files under `<name>.sempere/` (refuses an existing file). It is
  written to a temporary file, read back and checked member by member, then
  renamed. `tar xf FILE.tar` gives back a vault folder. `--json`: `archive`,
  `vaultId`, `files`, `bytes`, `sha256`.
- `backup verify DIR` without a key checks every file in `backup.json` (present,
  same size and SHA-256: a flipped byte or a missing file is found; a symbolic
  link counts as missing and is not followed) and that
  `vault.json` is well formed. With a key (`--identity`, `--recovery-key`,
  or this machine's device key for the vault; a passphrase-wrapped one only
  with a scripted passphrase) it also decrypts, tag-checks and decodes every
  revision like `vault verify`. Files on disk that `backup.json` does not list
  (`unindexed`, from a run cut short) are not problems. Exit 0 healthy, 3
  problems, 4 the key does not open the vault. `--json` emits `healthy`,
  `decrypted`, `backupProblems`, `vaultProblem`, `manifestProblems`,
  `counts` and `files` (`{path, status, detail}`; index
  statuses `ok`, `missing`, `modified`, `unindexed`, plus the vault check's
  problem statuses).
- `backup status DIR` reads `DIR/backup.json` only (no key, no other file)
  and prints the vault id, the first (`created`) and last (`updated`) run, the
  last run that finished without a file error (`completed`; absent, or
  `never` in text, until one does), and the `notes`, `files` and `bytes` it records, previous copies
  under `versions/` apart (`versionFiles`, `versionBytes`; `totalBytes` is
  both). `updated` moves with every run, failed or cut short ones too, so
  only `completed` says a backup worked. It checks nothing: `backup verify`
  does. Exit 0, or 1 when `DIR` is not a backup or its `backup.json` cannot
  be read. `--json` emits those fields.
- `backup status DIR --max-age DAYS` (1 to 3650) is the app's "Remind Me"
  for scripts: the backup is overdue when no run completed in the last DAYS
  days, counted from `completed`, else from `created` (a folder whose runs
  all failed is overdue DAYS
  days after its first run: one complete run clears it). A `completed` more
  than a day in the future (a clock that ran ahead, an edited file) counts as
  overdue rather than postponing the check. Overdue exits 3 and prints
  `OVERDUE` on the `due` line; `--json` adds `maxAgeDays`, `due` and
  `overdue`. The rule is the app's (`BackupSchedule`), with "last complete
  run" for the app's "last backup".
- `restore DIR --to NEWPATH` copies `vault.json`, `epochs/`, `keys/`, `notebooks/`, `settings.age` and `notes/` (not
  `versions/` or `backup.json`) into a new or empty folder ending in
  `.sempere`, checking every file against `backup.json`; a file that does not
  match, that `backup.json` does not list, or that is (or lies under) a
  symbolic link is not restored and is reported. `DIR` may also be any vault folder
  (say, an extracted tar). `vault.json` is written last, so an interrupted
  restore is never mistaken for a vault; the same command finishes it. The
  result is then verified: every revision with a key (as for `backup
  verify`), structure only without. Exit 0 ok, 1 files not restored, 2 usage (`NEWPATH` without
  `.sempere`), 3 the restored vault is not healthy, 4 wrong key. `NEWPATH`
  may not be, hold or lie inside the vault named by `--vault` or
  `$SEMPERE_VAULT` (exit 1: restore never touches a vault in use).
  `--dry-run` writes nothing: it refuses `NEWPATH` exactly as a restore would,
  then shows what `DIR` holds, read without a key: `notes`, `revisions`,
  `attachments`, `keyFiles`, `bytes`, `newestRevision` (the newest revision
  file's clock, so a device whose clock ran ahead can put it in the future),
  `isBackup` and `backupUpdated`. `--json` emits those fields with `source` and `vaultId`. A real restore's
  `--json` emits `vault`, `restored`, `alreadyPresent`, `errors`, `problems`, `healthy` and `decrypted`.

#### Scheduling backups

A backup run is cheap when nothing changed (it lists and compares sizes), so
run it often. Use absolute paths; no key is needed (do not put one in a
scheduled job unless you use `--prune`).

cron (Linux, macOS), every hour, plus a weekly check and a daily reminder
when no run has completed for a week (cron mails what a job prints: a quiet
`backup` prints nothing when all is well and the reminder only when a backup is
overdue, and `backup verify -q` prints nothing for a healthy backup):

```cron
0 * * * *  /usr/local/bin/sempere backup /home/me/Sync/notes.sempere --to /mnt/backup/notes -q
30 3 * * 0 /usr/local/bin/sempere backup verify /mnt/backup/notes -q
0 9 * * *  /usr/local/bin/sempere backup status /mnt/backup/notes --max-age 7 >/dev/null || echo "notes: no complete backup for 7 days"
```

launchd (macOS), `~/Library/LaunchAgents/io.github.anthonytw.sempere-backup.plist`,
then `launchctl load` it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.anthonytw.sempere-backup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/sempere</string><string>backup</string>
    <string>/Users/me/Library/Mobile Documents/com~apple~CloudDocs/notes.sempere</string>
    <string>--to</string><string>/Volumes/Backup/notes</string><string>-q</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardErrorPath</key><string>/tmp/sempere-backup.log</string>
</dict>
</plist>
```

(An iCloud Drive vault must be downloaded on that Mac: an evicted file is not
there to copy. Give `sempere` Full Disk Access if the target is an external
disk.)

systemd user timer (Linux), `~/.config/systemd/user/sempere-backup.service`
and `.timer`, then `systemctl --user enable --now sempere-backup.timer`:

```ini
# sempere-backup.service
[Unit]
Description=Back up the Sempere vault

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sempere backup %h/Sync/notes.sempere --to /mnt/backup/notes -q

# sempere-backup.timer
[Unit]
Description=Hourly Sempere backup

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

A failed run exits non-zero, which cron mails, launchd logs and
`systemctl --user status sempere-backup` shows. For an off-site copy, sync
the backup folder (or a weekly `--archive` tar) with any tool: it holds only
encrypted files.

#### The app's Backups (parity)

The iPad and Mac app (Settings ▸ Backups, `docs/io.md` "Backups in the app")
runs the same core code, so its backups are these backups: the app and the
CLI can each continue the other's folder, and everything above applies.

| App | CLI |
| --- | --- |
| Back Up Now | `backup V --to DIR` (after a failed Verify Backup, `--checksum`) |
| Verify Backup | `backup verify DIR` (with the key when the vault is unlocked) |
| Last Backup, Contents | `backup status DIR` |
| Restore from Backup: preview | `restore DIR --to NEW --dry-run` |
| Restore from Backup | `restore DIR --to NEW` (never into the open vault) |
| Remind Me | `backup status DIR --max-age DAYS` (exit 3 when overdue) in a scheduled job (below) |

The app never prunes (`--prune`) and does not write tar archives
(`--archive`): do those with the CLI. This is deliberate:

- **`--prune`** deletes revisions from the backup once the vault has
  compacted them away. Keeping them is what a backup is for: it is the only
  copy of history that thinning (the app's, or `compact --thin-older-than`)
  or a mistaken compaction removed, and nothing in the app can bring that back.
  The cost is space in the backup folder only. Whoever wants the backup to
  shrink with the vault decides it once, with the key, in the CLI.
- **`--archive`** writes one tar next to the backup; on an iPad that is a
  second full copy of the vault in local storage before it can be moved
  anywhere, and the backup folder is already a complete vault that Files can
  copy or compress (Files → Compress) as it is.

### Notes

```
sempere notes list [--tag T] [--notebook N] [--deleted] [--favorites] [--sort title|modified|created] [--favorites-first] [--no-cache]
sempere notes show ID|TITLE
sempere notes new [TITLE] [--title-format PATTERN] [--notebook PATH] [--tag T]... [--paper KIND] [PAPER OPTIONS] [--page-size letter|a4] [--no-cache]
sempere notes rename ID|TITLE NEW-TITLE
sempere notes tag ID|TITLE [--add T]... [--remove T]... [--no-cache]
sempere notes move ID|TITLE (NOTEBOOK | --none)
sempere notes paper ID|TITLE [KIND] [--page N] [PAPER OPTIONS]
sempere notes language ID|TITLE [TAG | --none]
sempere notes markers ID|TITLE behind|above
sempere notes favorite ID|TITLE [--off]
sempere notes search QUERY [--notebook PATH] [--tag T] [--deleted] [--no-cache]
sempere notes delete ID|TITLE
sempere notes undelete ID|TITLE
sempere notes history ID|TITLE [--sessions]
sempere notes restore ID|TITLE --to REVISION [--dry-run]
sempere notes checkpoint ID|TITLE [--name TEXT]
sempere notes layout ID|TITLE paged|pageless [--dry-run]
sempere notes dedupe (ID|TITLE ... | --all) [--dry-run]
```

`list` prints id, title, pages, strokes and last modified; deleted notes are
hidden unless `--deleted`, and `--favorites` lists only favorites. Notes are in
title order (Finder order: `Note 2` before `Note 10`) unless `--sort modified`
or `--sort created` (newest first, notes without the date last);
`--favorites-first` puts the favorites ahead of the other notes, each group in
that order. These are the app's note-list rules (`NoteOrder`). `--notebook` takes a notebook path and lists the
notes in it or below it, comparing whole segments (`A/B` holds `A/B/C` but not
`A/Bc`), as the app's sidebar does; `--tag` ignores case. Notes are read in parallel without their stroke
geometry, and the summaries are kept in an encrypted per-device cache
(`$XDG_CACHE_HOME/sempere/`, default `~/.cache/sempere/`; `format.md` §10), so
a later `list` reads only notes whose revision files changed. A damaged cache
is ignored and rewritten; `--no-cache` neither reads nor writes it. `show` prints the metadata, how many pages have recognized text (`Text:`; `recognizedPages`
in `--json`), the note's placed items (text boxes, images, PDF pages, unknown
kinds; by page in drawing order: page, kind, layer, frame, the text or the
blob's type, size and hash prefix, id) and recordings (start, duration, title,
blob, whether it has a transcript, id), and the revision history
(kind, wall time, file name; `-v` adds the app string). `--json` adds `items`
(each `{page, pageId, item}`, `item` in its `format.md` §8.2 form) and
`recordings` (§8.3.1 form), both without the snapshot-only `origin` and
`clocks`; `list --json` gains the counts `items` and `recordings`, `created`, and
`attachments`: the kinds of attachments the note holds, among `image`, `math`,
`video`, `audio` (recordings or audio cards) and `pdf`, in that order (the
app's row icons). A note is named by its
full id, an id prefix of 4 or more characters, or its exact title
(case-insensitive); an ambiguous name is an error that lists the candidates.

`history` lists the note's restore points, one per readable revision, oldest
first by `(hlc, device, seq)`: kind, wall time, device, app and revision name.
`--json` gives `revision`, `kind`, `hlc`, `device`, `seq`, `wall`, `app`,
`complete`, `checkpoint` (true for a saved version), `name` (the checkpoint's
name, if any), `session` (the editing-session id the app wrote, if any) and
`group` (the index of the point's group, below) per point. A checkpoint is
marked `(checkpoint: NAME)` in the text output. `--sessions` groups the points
as the app's history view does (`docs/format.md` §5.8.2): each checkpoint on
its own, and the autosaves between checkpoints in editing sessions; a new
session starts when the note was closed and reopened (another `session` id),
after a gap of 10 minutes or more, or when another device wrote. The text
output is one line per group (GROUP, FROM, TO, DEVICE, SAVES, NEWEST); `--json`
gives an array of groups, oldest first, each with `type` (`checkpoint` or
`session`), `device`, `session`, `name` (checkpoints), `start`, `end`, `saves`,
`newest` (the revision thinning keeps) and `points` (as above). Snapshots that
`compact` writes "as of" a kept version (`asOf`, `docs/format.md` §5.8.3) are
bookkeeping and are not listed. Revisions deleted by `compact` are not restore points. A
point is `complete: false` (shown as `(incomplete)`) when the note as of it can
no longer be rebuilt: revisions before it were compacted away and no snapshot
at or before it covers them, or one before it (or any snapshot) is unreadable. Unreadable
revisions are not listed; a warning on stderr counts them.

`restore` makes the note look as it did at `REVISION` (the merge of every
revision up to and including it, `docs/format.md` §5.7) by writing **one new
delta**; no existing file is changed or deleted. Pages and strokes added since
are removed, those removed since are re-added under new ids with `parent`
naming the old id, and title, tags, notebook, favorite, paper, page size, page
order, recognition and the deleted flag are set back. Placed items and
recordings follow the same rule (re-added with their register values as of the
point; changed registers such as an item's frame or text or a recording's
title are set back; an item moved to another page since goes back to its page). `REVISION` is a name from
`history`, with or without its `.delta.age`/`.snapshot.age` suffix, or a unique
prefix of 6 or more characters. If the note already matches, nothing is written
(restoring twice is a no-op). `--dry-run` prints what would change
(`would restore ...: remove 1 page(s); re-add 1 stroke(s); set tags`) and
writes nothing. The delta is stamped with this machine's device id and clock,
as for `snapshot`. Restoring needs every revision of the note to be readable;
an incomplete restore point is refused. `--json` emits `note`, `to`, `dryRun`,
`changed`, `file` (the delta written, if any) and `changes` (`pagesRemoved`,
`pagesRestored`, `strokesRemoved`, `strokesRestored`, `pageOrderChanges`,
`recognitionChanges`, `pagePaperChanges`, `itemsRemoved`, `itemsRestored`,
`itemChanges`, `recordingsRemoved`, `recordingsRestored`, `recordingChanges`,
`metaFields`, `deleted`).

`checkpoint` saves the note as it is now as a version, optionally named
(`--name`, trimmed, at most 200 characters): one delta with no ops marked as a
checkpoint (`docs/format.md` §5.8.1), stamped with this machine's device id and
clock as for `snapshot`. The app's Save Version writes the same. Checkpoints are
restore points like any other (`notes restore --to`, `export --at`), and
`compact` never deletes one. `--json` emits `note`, `file`, `name` and
`device`.

`layout` switches a note between paged (fixed-size pages) and pageless (one
infinite page) by writing **one new delta** (`docs/format.md` §5.4.3).
`pageless` joins the pages into the first one, each page's ink shifted down by
its offset, with the old page height as the sheet height (`breakHeight`);
`paged` cuts each infinite page into pages of its sheet height, a stroke going
to the sheet that holds its vertical center. No ink is deleted and none moves
relative to its sheet; strokes that change page are re-added under new ids with
`parent` naming the old ones, so `pageless` then `paged` gives the pages back.
The switch is computed from the note as it is on disk when the delta is
written. Nothing is written when the note already has the layout (a pageless
note with several pages, left by concurrent edits, is joined), or with
`--dry-run`. A deleted note is refused (exit 1).
The device id and clock are this machine's, as for `snapshot`. `--json` emits
`note`, `layout`, `dryRun`, `changed`, `pagesBefore`, `pagesAfter` and `file`.

`search` finds notes as the app's search box does (`NoteSearch`, shared with
the app): the query is words, and a note matches when every word is found in
its title, notebook, tags or a page's recognized text (case, accents and width
ignored, substrings count); a word starting with `#` matches tags only. Notes
are ranked as in the app (exact title and tag matches first, then the page
holding most of the words) and printed best first with the matching fields,
the best page and a snippet. `--notebook` (that notebook and below) and `--tag`
narrow the search as selecting a notebook or tag in the sidebar does;
`--deleted` searches Recently Deleted instead. `--json` gives `note`, `title`,
`notebook`, `tags`, `fields` (`title`, `tag`, `notebook`, `text`), `page`
(`number`, `id`), `snippet`, `matchedPages` and `score` per note. The snippet quotes prose only, cut at word boundaries
within one text segment (an equation's LaTeX source is searched but never
quoted: a match inside an equation prints `[equation]`). For every
occurrence of a phrase, with word boxes, use `sempere search`.

#### Editing notes

The editing commands make the same changes as the app's note browser and
canvas, with the same core code (`NoteOps`, `Vault.apply`): each writes **one
delta** per note, stamped with this machine's device id and clock
(`$XDG_STATE_HOME/sempere/device.json`, as for `snapshot`), and nothing at all
when the note already is that way. A note with an unreadable revision is not
edited (exit 1): ops computed from part of a note could undo the rest. Notes
are named as for `show`. With `--json` each prints `note` (the note after the
edit, as in `notes list --json`), `changed` and `file` (the delta written, or
absent).

- `new` creates a note with one blank page: title (trimmed; titles need not
  be unique), notebook, paper (default `ruled`, with the paper options below),
  page size (`letter`, the default, or `a4`) and one `addTag` per `--tag`, in
  the spelling the vault already uses for that tag (as `tag --add` below).
  Prints the new id (the `Created …` line goes to stderr). Without a TITLE
  the note is named after the date and time, as the app names a new note
  (`DefaultTitle`): `--title-format` (default: the `SEMPERE_TITLE_FORMAT`
  environment variable, this machine's setting, as the app's Settings ▸ New
  Notes → Title is the device's) takes a Unicode date pattern
  (`"yyyy-MM-dd HH:mm"`, literal text in single quotes: `"'Lecture' EEE d MMM"`,
  `''` for a quote) or a strftime format (`"%Y-%m-%d %H:%M"`, `"Lecture %a %e %b"`:
  any `%` outside quoted text makes it one, and its other characters are
  literal; `%Y %y %m %B %b %d %e %j %A %a %u %H %I %k %l %M %S %p %F %R %T %D
  %Z %z %%`, with `-` for no leading zero: `%-d`). A format the app's setting
  would refuse (an unclosed quote, a letter that is no date field, an unknown
  `%` directive, one that gives no text, over 200 characters) is refused with
  the same reason and exit 2. Without one the title is the locale's medium date
  and short time. `""` is an empty title.
- `rename` sets the title (trimmed).
- `tag` adds and removes tags in one delta. Tags match case-insensitively and
  merge per tag (`format.md` §5.4.1): `--add` writes an `addTag` unless the
  note has the tag in any spelling, in the spelling the vault already uses
  for it ("math" becomes "Math" if another note has "Math"); `--remove`
  writes a `removeTag` observing every instance of the tag. Adding and
  removing the same tag is a usage error.
- `move` puts the note in a notebook, a `/`-separated path stored in
  canonical form (`" A//B "` is `A/B`); `--none` (or an empty name) takes it
  out of any notebook.
- `paper` sets the paper. Without `--page` the note's paper is set and every
  page with its own paper follows the note again (`setMeta paper` plus
  `setPagePaper null`); `--page N` (1 is the first page) gives only that page
  its own paper (`setPagePaper`). `KIND` starts from that kind's defaults, as
  the app's picker does; without it, the options change the current paper of
  the note (or the page). A deleted note is refused (exit 1). `--json` prints
  `note` (the id), `changed`, `file`, `page` and `paper` (in the format's JSON
  form).
- `language NOTE [TAG | --none]` sets the language the note is handwritten
  in (`format.md` §5.4 `lang`), a BCP 47 tag (`en-US`, `es`, `pt-BR`;
  `en_US` is read as `en-US`); `--none` clears it. `recognize` and the app ask
  Vision for it when Vision supports it, else detect the language. Without a
  tag it prints the note's language (`--json`: `{note, lang}`). A tag that is
  not BCP 47 is a usage error (exit 2).
- `markers NOTE behind|above` draws the note's marker (highlighter) strokes
  below its text boxes and images and below other ink (`behind`), or with the
  rest of the ink above every item (`above`, the default) (`format.md` §5.4
  `markersBehindText`, §8.2.3). Imported Notability notes are `behind`.
- `favorite NOTE [--off]` marks the note as a favorite (`format.md` §5.4
  `favorite`), or with `--off` takes the mark off; one delta, nothing written
  when the note already is that way. `list --favorites` lists the marked
  notes. The app's Favorites list and the web viewer's show them.
- `delete` moves the note to Recently Deleted; `undelete` brings it back.
  (`restore` is a different thing: it rolls a note back to an earlier
  revision.)

Paper kinds (`format.md` §5.4.2): `blank`, `ruled`, `grid`, `dot`,
`marginRuled`, `isoDot`, `isoGrid`, `cornell`, `staff` (any case; `margin-ruled`
works too). Paper options, in points unless stated; a value outside the
format's limits is a usage error (exit 2), not clamped:

| Option | Range | |
| --- | --- | --- |
| `--spacing` | 4–200 | line, dot or grid spacing |
| `--line-width` | 0.1–4 | rules |
| `--dot-radius` | 0.3–4 | `dot`, `isoDot` |
| `--margin-left`, `--margin-top` | 0–300 | margin lines from the edge; 0 is none |
| `--cue-width`, `--summary-height` | 40–400 | `cornell` |
| `--staff-spacing` | 3–20 | `staff`: between lines |
| `--staff-gap` | 8–150 | `staff`: between staves |
| `--background`, `--line-color`, `--margin-color` | `#RRGGBB` or `#RRGGBBAA` | colors |

```
sempere notes new "Week 3" --notebook School/Physics --tag physics --paper grid --spacing 18
sempere notes paper "Week 3" cornell --page 2      # needs a second page: sempere pages add "Week 3" first
sempere notes tag "Week 3" --add exam --remove draft
sempere notes language "Week 3" es-ES
sempere notes markers "Week 3" behind
sempere notes favorite "Week 3"
sempere notes list --favorites --json
```

`notes list --json` (and the `note` of every edit's `--json`) includes `lang`
(when set), `markersBehindText` and `favorite`.

#### Strokes left over by concurrent edits

When two devices slice (pixel eraser), move or recolor the same stroke
without seeing each other's edit, every reader keeps the later edit and hides
the other one's strokes (`format.md` §5.6.1). `notes dedupe` lists, per note:

- **superseded** strokes: hidden that way, but still added by revisions;
  removing them makes the revisions say what every reader shows.
- **duplicates**: live strokes that descend from the same stroke as other
  live strokes through another edit, which the merge cannot resolve: a stroke
  brought back by undo or a restore while another device sliced it. The
  descendants of the latest edit are kept.

Without `--dry-run` it writes one delta per note that has any (one
`removeStroke` per stroke, computed from the note as it is on disk; device id
and clock as for `snapshot`); `--dry-run` is the check and writes nothing.
Notes are named as for `notes show`, or `--all` for every note; with `--all` a
note that cannot be read is reported on stderr, the others are still
processed, and the exit code is 1. `--json` prints one object per note:
`note`, `superseded` and `duplicates` (each `[{page, stroke}]`), and `file`
(the delta written, null on a dry run or when there was nothing).

```
sempere notes dedupe --all --dry-run
sempere notes dedupe "Week 3"
```

### Notebooks and tags

```
sempere notebooks list [--deleted] [--no-cache]
sempere notebooks create PATH
sempere notebooks rename OLD NEW [--dry-run]
sempere notebooks move NOTEBOOK (PARENT | --top-level) [--dry-run]
sempere notebooks delete PATH [--dry-run]
sempere tags list [--no-cache]
```

`notebooks list` prints the notebook tree (parents included, even when they
hold no note directly) with `NOTES`, the notes directly in a notebook, and
`TOTAL`, those in it or below it; deleted notes count only with `--deleted`.
Empty notebooks kept by notebook records (format.md §14) are listed too, with
`DECLARED` `yes`. `--json` gives `path`, `depth`, `notes`, `total` and
`declared` per notebook. A record that cannot be read is reported on stderr and
skipped (it then neither declares nor removes anything).

`notebooks create` makes an empty notebook (the app's New Notebook): one
notebook record declaring `PATH` (`/` for levels; parent levels need nothing),
so it is listed, and stays when the notes put in it later leave again. Nothing is
written when `PATH` is declared already. `--json` gives `notebook`, `created`
and `record` (the file written under `notebooks/`).

`notebooks rename` renames or moves a notebook with everything below it: each
note in `OLD` or below it, deleted ones too, gets the `OLD` prefix of its
notebook replaced by `NEW`, one delta per note (as the app's sidebar rename).
Paths compare by whole segments, so renaming `A/B` leaves `A/Bc` alone. An
empty `NEW` (`""`) takes the notes directly in `OLD` out of any notebook and
lifts its sub-notebooks to the top level. Every note is read first, without
the cache; if any cannot be read the command writes nothing and exits 1 (its
notebook is unknown, so it would be left behind). `--dry-run` lists the notes
that would move. Empty notebooks within `OLD` (records, format.md §14.4) are
renamed too, by one record written before the notes' deltas. `--json` gives
`from`, `to`, `dryRun`, `notes` (`note`, `title`, `from`, `to`, `file`),
`declared` (the empty notebooks renamed) and `record`.

`notebooks move` is what dragging a notebook onto another does in the app (or
"Move Notebook To…"): `NOTEBOOK` keeps its last level and takes `PARENT` as its
parent, so `notebooks move School/Math Archive` makes `School/Math` →
`Archive/Math`, every note below it coming along (the same prefix rename,
deleted notes included, one delta per note, same refusals and `--json` as
`notebooks rename`). `""` or `--top-level` un-nests it. Moving a notebook into
itself or a notebook inside it is a usage error (exit 2, nothing written), and a
notebook that already has the name at the destination is merged with it.
Moving into the notebook it is already in changes nothing. Notes are moved with
`notes move`.

`notebooks delete` deletes an empty notebook and the empty notebooks inside it
(one record ending the records that declare them). It never deletes or moves a
note: while a note that is not deleted is in `PATH` or below it, it exits 1 and
writes nothing (move or delete the notes first). Notes in Recently Deleted keep
their notebook, so restoring one shows the notebook again. A notebook that only
notes name (no record) is not deleted by this command: it goes when its last
note leaves. `--json` gives `notebook`, `removed`, `dryRun` and `record`.

`tags list` prints each tag once (tags match case-insensitively; the first
spelling found is shown, as in the app's sidebar) with the number of notes
that carry it. Deleted notes do not count. `--json` gives `tag` and `notes`.

### Pages

```
sempere pages list ID|TITLE
sempere pages add ID|TITLE [--count N] [--after PAGE]
sempere pages move ID|TITLE PAGE --to PAGE
sempere pages delete ID|TITLE PAGE
sempere pages duplicate ID|TITLE PAGE
sempere pages scribble ID|TITLE [--page N] [--strokes N] [--points N] [--per-revision N] [--seed N]
                       [--top Y] [--row-height PT] [--recording ID]
```

`list` prints each page's number, id, stroke count, paper (its own, or the
note's marked `*`) and whether it has recognized text. `--json` gives `note`,
`paper` and `pageSize` (the note's) and `pages` (`page`, `id`, `strokes`,
`paper` when the page has its own, `recognized`).

`add` appends `N` blank pages (1–100, default 1) after the last page, or
after page `--after` (0: before the first), in one delta, as the app's Add
Page; they follow the note's paper.

The page gestures of the app (`docs/format.md` §5.4.3), one delta each, with
1-based page numbers as `list` prints them: `move` puts a page at position
`--to` (one `setPageOrder`; nothing when it is already there), `delete`
removes a page and its ink (`removePage`; a note keeps at least one page,
and `notes restore --to` undoes it), `duplicate` copies a page's ink, items,
paper and recognized text right after it under new ids.

`scribble` writes synthetic handwriting, for test fixtures, stress tests and
benchmarks (the app's dense-page tests use the same generator, `SyntheticInk`):
`--strokes` (1–200 000, default 1000) word-sized pen loops of `--points`
control points (2–500, default 24) in rows `--row-height` apart (4–200, default 24) from
`--top` down (0–1 000 000, default 48), between the page margins, as `addStroke` ops on page
`--page` (default 1). `--per-revision` writes them that many to a delta (default:
all in one), so `--strokes 300 --per-revision 1` makes a note of 300 revisions;
the note is read once for all of them. The same `--seed` (default 1) gives the same
geometry; stroke ids are new each run. `--recording` links every stroke to a
recording of the note (`rec`, format.md §5.6), spread evenly over its length,
as ink written while it ran. `--json` gives `note`, `page` (its id), `strokes`
and `files` (the revisions written). A dense page for the app's checks:
`notes new Dense`, `notes layout Dense pageless`, then `pages scribble Dense --strokes 20000`.

A deleted note is refused (exit 1), as is a page number out of range.
`--json` as for the editing commands.

`notes dense` makes a whole dense note for performance work (the app's `DensePerformanceTests` write the same
note in process, `DenseNote` in SempereRender):

```
sempere notes dense TITLE [--pages N] [--strokes N] [--points N] [--images N] [--image-size PX]
                          [--seed N] [--notebook PATH] [--pageless]
```

It writes a new note of `--pages` pages (1–500, default 40; `--pageless`: one long page instead) holding
`--strokes` strokes in all (0–500 000, default 20 000; the same generator as `pages scribble`, spread evenly over
the pages, `--points` control points each, default 16) and `--images` pictures (0–500, default 12; seeded noise
PNGs of `--image-size` pixels, default 480, stored as blobs and placed down the pages). One delta makes the
note and its pages, then one delta per page holds its strokes and pictures. The same `--seed` gives the same
geometry and pictures; ids are new each run. Prints the note's id; `--json` gives `note`, `pages`, `strokes`,
`images` and `files`.

### Items

```
sempere items list ID|TITLE [--page N]
sempere items move ID|TITLE ITEM --frame x,y,w,h
sempere items rotate ID|TITLE ITEM --degrees D
sempere items crop ID|TITLE ITEM (--crop x,y,w,h | --clear) [--keep-frame]
sempere items replace ID|TITLE ITEM FILE [--keep-metadata]
sempere items text ID|TITLE ITEM (TEXT | --file FILE|-) [--markdown | --no-markdown] [--no-breaks]
sempere items math ID|TITLE ITEM [--latex SOURCE | --latex-file FILE|-] [--display | --no-display]
                                 [--size PT] [--color #RRGGBB[AA]] [--render FILE.pdf [--engine NAME]]
sempere items front ID|TITLE ITEM
sempere items delete ID|TITLE ITEM...
sempere items duplicate ID|TITLE ITEM... [--dx PT] [--dy PT]
sempere items copy ID|TITLE ITEM... --to ID|TITLE [--page N]
sempere items poster ID|TITLE ITEM (IMAGE | --from-clip [--poster-time S] | --remove) [--dry-run]
```

**Markdown text boxes** (`format.md` §8.2.4 "Markdown text", §8.5.4).
`attach text --markdown` stores the text as Markdown source with LaTeX math:
headings, `**bold**`, `*italic*`, `~~strikethrough~~`, `` `code` ``, bullet,
ordered and task lists (`- [ ]`, `- [x]`), links, block quotes, fenced code
blocks, thematic breaks, inline `$…$` and display `$$…$$` math; every line
break shows as a line break. The source is the box's text (one run); the
line breaks stored are those of the
rendered text, laid out with the CLI's fonts (`layout`, with the hash of the
text they belong to), and the frame is as tall as the rendered lines.
`--bold` and `--italic` are refused with `--markdown` (Markdown says it). The
CLI cannot typeset: formulas are drawn as their LaTeX source (in a monospace
font, reported by `export`) until the app typesets the box. `items text`
replaces a box's text in one delta (the `text` register and, when the height
of its lines changes, the frame): a Markdown box gets the new source and
keeps its style and the typeset formulas the new source still uses; a plain
box gets the text as one run in its style (run styles are dropped);
`--markdown` turns a plain box into a Markdown box in the same font, size,
color, alignment, direction and language, `--no-markdown` the other way; the
text is laid out again unless `--no-breaks`. `items list` shows a text box's
text as search sees it (Markdown without markup) and `(Markdown)`; `--json`
adds `text` and `markup`. `items move` lays a Markdown box out again at a new
width like any laid-out box. `search` matches a Markdown box's text without
its markup, `export` draws it rendered (PDF, SVG, PNG), the Markdown export
writes the source as it is and the HTML export renders it.

Recordings on the page (audio items, `format.md` §8.2.9) are placed with
`recordings place` or `attach recording --place`; `list` shows them with the
recording they show (`--json`: `recording`, and `recordingMissing` when the
note has no such recording), and they move, resize, rotate, reorder,
duplicate and delete like any item. `copy` to another note leaves them out
(with a warning): the recording belongs to its note.

The app's gestures on placed items (text boxes, images, PDF pages, video clips, equations;
`docs/format.md` §8.2), one delta each, built by the same `NoteOps` item
builders as the app's canvas and computed from the note as it is on disk when
the delta is written. An item is named by its id or an id prefix of at least
4 characters (an ambiguous prefix is refused); the items of one command must
be on one page. `list` prints page, id prefix, kind, frame and attachment
(`--json`: `page`, `id`, `kind`, `layer`, `frame`, `rotation`, `z`, `blob`, `crop`,
and for a video `duration` and `poster`, for an equation `math`, its whole
value, with `blob` its rendering; the table shows a video's length and
`+poster` or `(no poster)`, and an equation's source, marked `(not typeset)`
without a rendering). `poster` sets a video's poster frame (a JPEG or
PNG, stored upright without metadata; `--from-clip` on macOS takes it from the
clip at `--poster-time`, default 0.5 s) or removes it (`--remove`): one
`setItem` of the `poster` register (`format.md` §8.2.7), nothing when the video
already has that poster (`--json`: `note`, `item`, `poster`, `file`,
`changed`). `copy` copies a video's clip and poster into the target note.
`move` sets the frame (move and resize; a text box with stored `breaks` that
gets another width is laid out again with the CLI's fonts, its new `breaks`
and the height of its lines written in the same delta, as the app does), `rotate` the rotation, `crop` the
part of an image or PDF page shown (`--crop` in the source's coordinates:
pixels of the upright image, or points on the PDF page's visible box; clamped
to the source; `--clear` shows all of it): the frame follows so the part that
stays visible keeps its place and size on the page, as the app's Crop, unless
`--keep-frame` (`NoteOps.setCrop`; a text box is refused), `replace` swaps an
image's picture for a JPEG or PNG, as the app's Replace Image: an image's blob
cannot change in place (`format.md` §8.2.2), so after the new picture is
stored (without its metadata unless `--keep-metadata`) one delta removes the
old image and adds a new one whose `parent` names it, in the largest frame of
the new picture's proportions inside the old frame, centered on it, with the
old rotation and stacking and no crop (`NoteOps.replaceImage`; anything but an
image is refused before anything is written; prints the new item's id;
`--json`: `note`, `changed`, `file`, `item`, `replaced`, `blob`), `math` writes an
equation's whole value (`NoteOps.setMath`, `format.md` §8.2.8): the options
given replace the source, style, size or color, checked as `attach math`
does; any such change drops the rendering (the CLI cannot typeset) unless
`--render` gives one for the new value, and a new rendering also sets the
frame (same top-left corner, its size times the scale the frame had to the
previous rendering, 1 without one), `front`
draws the item above the others of its layer, `delete` removes items (their
attachments stay until `blobs gc`), `duplicate` copies them on their page
shifted by 20 points (or `--dx`, `--dy`), and `copy` copies them to a page of
another note, its attachments first (verified as they are read), as the app's
Paste. Nothing is written when the item already is that way; a deleted note
is refused (exit 1). `--json` as for the editing commands.

### Import

`sempere import` has one subcommand for each importer the build contains (`notability` and the built-in `pdf`).
An importer is a module (`docs/import-notability.md` "Structure"): its flags come from its option specs, and
`--notebook`, `--dry-run`, `--pdf-text`, `--recognize` and the vault and output options are the same for all of them.
Without the Notability module `sempere import` lists only `pdf`; nothing else changes.

```
sempere import notability PATH... [--notebook N] [--overwrite] [--dry-run] [--no-scale]
                                   [--no-folder-tags] [--tag T ...] [--no-attachments]
                                   [--keep-image-metadata] [--recognize missing]
                                   [--pdf-text auto|builtin|poppler|none]
```

Each `PATH` is a `.note` or `.ntb` file, an unzipped `.note` package
directory, a folder searched recursively for both, or a zip of them
(pass **every part** of a backup split into several zips in one run); see `docs/import-notability.md` for the
mapping. All inputs are read before anything is written, so copies of one
note anywhere in them are resolved together: the newest `.note` with ink is imported,
copies whose strokes it already has are skipped (`duplicate:`, `older
version:`, or `superseded:` for an `.ntb` copy, each naming the source that
was imported), and a copy holding strokes the chosen one lacks is imported as
a separate note titled `<title> (version modified <date>)` and gets a
`separate version …` line. An `.ntb` without a `.note` is imported from the
bundle.

On a terminal (or with `SEMPERE_PROGRESS=always`; never with `--json` or `--quiet`) a progress line on stderr
counts the sources as they are read (`Reading 120/1531 notes: Lecture 4.note`) and then written
(`Importing …`). Ctrl-C stops the import after the note being written: every note written stays whole (one
delta each), the rest are reported as `skipped` with `not imported: the import was canceled` (one
`Canceled: N note(s) not imported` line, `"cancelled": true` in the JSON summary) and the command exits 1;
running it again imports the rest, since notes already in the vault are skipped. A second Ctrl-C quits at once.

One row is printed per input file (status, title, notebook, strokes written,
pages with recognized text, source) plus a summary line; `-v` lists what was
left behind (typed text, PDFs and their page count, media, recordings, PDF
highlights, template PDF paper, dashed strokes, strokes with defaulted
attributes, shapes or `.ntb` strokes not decoded, `.ntb` strokes placed at the
page edge) and one `attachments …` line per attachment warning (a PDF that is
missing, encrypted or unreadable, a page number beyond the PDF, a media object
with no file or no frame together with its Notability field names, an image
format the vault does not store, and how each image was placed).

Attachments (`docs/import-notability.md` "Attachments"): the PDF pages of a
note made from a PDF become `pdfPage` backgrounds at the bands where
Notability showed them, backed by the original PDF as one blob of the note,
images become `image` items, typed text becomes `text` items (styles mapped
to runs), and recordings become the note's recordings with their audio
(strokes get `rec` where `eventTokens` read as times in the one recording; a transcript
Notability kept with a recording becomes its transcript blob, `engine` `notability-<version>`,
counted as `transcripts`);
blobs are written before the note's delta.
JPEG and PNG metadata (camera, location) is stripped unless
`--keep-image-metadata`; HEIC is stored as is; GIF (first frame) and baseline
TIFF are converted to PNG; WebP and other formats are reported and left out. `--no-attachments` imports ink, recognized
handwriting and metadata only and reports every attachment as dropped. A note with
no ink and none of its PDF pages imported gets a `no ink in …` line. A note
already in the vault is skipped unless `--overwrite`, which
replaces its pages. `--notebook` files every note under one notebook;
`--no-scale` keeps Notability's document units instead of scaling to 612 pt
width. Notes are tagged with their Notability folder names (`Research/Daily
log` → `Research`, `Daily log`, besides Notability's own tags; matched
case-insensitively) unless `--no-folder-tags`; `--tag T` (repeatable) adds T
to every imported note. Tags are written as a whole, so `--overwrite` of a
note that moved folders drops the old folder's tags. The device id and clock
come from `device.json` as for `snapshot`.

`.ntb` bundles keep their PDF and images as top-level `<sha256>.pdf` /
`.jpeg` / `.png` files: they are imported as for a `.note` (PDF pages as
backgrounds, one per Notability page; images at their record's rectangle),
and the bundle's strokes are moved to the PDF's page tops. Each note's
handwriting language (`NBNoteTakingSessionHandwritingLanguageKey`, `es_ES` →
`meta.lang` `es-ES`), its highlighter-behind-text flag (`markersBehindText`)
and a `paperColor` (the paper's background) are imported too.

Every imported PDF page gets its text for search (`pageText`, `format.md`
§8.2.6): from Notability's own index (`NBPDFIndex/PDFIndex.zip`,
`ios/PDFIndex.fb`) where it maps to the pages, else extracted from the PDF
with `--pdf-text` (default `auto`: Poppler's `pdftotext` when installed, else
the built-in reader; `none` stores the index's text only).

`--recognize missing` reads the handwriting of every imported page that has
ink but no recognized text in the backup right after the
import, as `sempere recognize --missing-only` does (see "Handwriting
recognition"); Notability's own recognition is never replaced. It needs
macOS: elsewhere the import is refused before anything is written (exit 1).
With `--dry-run` it lists the pages it would read. `--json` then adds
`recognized`, one entry per imported note as in `recognize --json`.

`--dry-run` imports into a throwaway copy of the vault with a throwaway device,
so the report is exact but neither the vault nor `device.json` is touched.
`--json` emits `summary` (`notes`, `imported`, `skipped`, `failed`,
`strokes`, `ntb`, `extraVersions`, `dryRun`, and over the notes written
`pdfPages`, `images`, `textItems`, `recordings`, `recLinkedStrokes`, `blobs`,
`blobBytes`, `droppedPDFPages`, `droppedMedia`, `pdfs`, `ntbPDFPages`,
`ntbImages`, `ntbDroppedPDFs`, `pdfTextPages`, `pdfTextFromIndex`,
`pdfTextExtracted`, `pdfPagesWithoutText`, `languages` (tag → notes),
`markersBehindText` and `paperColors` (notes)) and `notes` (with `status` `imported`, `skipped` or `failed`,
`reason`, `id`, `format` `note`/`ntb`, `shapes`, `duplicateOf`,
`extraVersion`, `selection`, `dropped` (`pdfs`, `pdfPages`, `media`,
`pdfHighlights`, `templatePDFs`, `typedTextCharacters`, `recordings`,
`recLinks`, `bundleRecordsWithoutFile`, `bundleFilesUnreferenced`,
`pdfTextPages`, …), `attachments` (`pdfs`, `pdfPages`, `templatePages`, `images`,
`textItems`, `textCharacters`, `recordings`, `recLinkedStrokes`, `blobs`,
`blobBytes`, `pdfTextPages`, `pdfTextFromIndex`, `pdfTextExtracted`,
`bundlePDFRecords`, `bundleMediaRecords`, `bundleFiles`, `bundleFilesImported`),
`lang`, `markersBehindText`, `paperColor` and `warnings`, ...). A skipped note's `dropped` counts
everything its source holds, since nothing of it was written. Exit 1
if any note failed, a path does not exist, or no `.note` or `.ntb` file was
found.

#### `import pdf`

```
sempere import pdf FILE... [--title T] [--notebook N] [--tag T ...] [--pages 1-3,5,7-]
                           [--pdf-text auto|builtin|poppler|none] [--dry-run]
```

Makes a **new note from each PDF**: the PDF is stored as one blob of the note
and every page becomes a note page with a `pdfPage` item filling it in the
background layer, so the note opens as a PDF to annotate (`docs/attachments.md`
§8). The note's page size is the first page's effective size (crop box,
rotation); later pages of another size are fitted and centered; paper is blank.
The whole note is one delta. The title is `--title` (one file only) or the file
name without `.pdf`; `--notebook` and `--tag` as for `notes new`; `--pages`
imports a subset. Encrypted PDFs (remove the password first, e.g. `qpdf
--decrypt`), non-PDFs, files over 1 GiB and PDFs with more than 2 000 pages are refused. Prints
each new note's id (`-q`: only the ids); a file that fails does not stop the
others and the exit code is 1. `--dry-run` checks the files and writes nothing.
`--json` emits `{dryRun, imported, failed, notes}`, one entry per file:
`source`, `status` (`imported`, `would import`, `failed`), `reason`, `id`,
`title`, `pages`, `blob`, `file`, `pagesWithText`, `textEngine`. Exports draw
the pages as the originals (see "PDF page backgrounds").

**PDF text.** `import pdf` and `attach pdf` store each page's text as the
item's `pageText` (`format.md` §8.2.6) so `search` and `notes search` find
words on PDF pages. `--pdf-text auto` (the default) runs Poppler's
`pdftotext` when it is installed (`SEMPERE_PDFTOTEXT` names another binary;
it runs as `pdftoppm` does for exports: no shell, resource limits, a timeout,
a private temporary directory), else the built-in pure-Swift reader
(`semperepdf-1`: the strings each page shows, decoded through the fonts'
`/ToUnicode` maps or standard encodings, in content order; no layout
analysis, so multi-column text comes out in drawing order; form XObjects
drawn by a page may add at most 16 MiB of lexed content to it and 128 MiB
to the file, past which the page keeps the text found so far). `builtin` and
`poppler` force one (`poppler` without `pdftotext` is an error); `none`
stores no text. A page with no extractable text (a scan) stores nothing.
`attach pdf --json` adds `pagesWithText` and `textEngine`.

### Search

```
sempere search TERM [--transcripts] [--show-boxes]
```

(To find notes rather than every occurrence, ranked as in the app, use
`notes search`.)

Case-insensitive, accent-insensitive substring search over every page's
recognized handwriting text (imported or on-device recognition),
**the text of every text box, the LaTeX source of every equation and the
stored text of every PDF page**
(`pageText`, see `import pdf`), in all notes except deleted ones. With
`--transcripts` it also searches the transcript of every recording, which means
decrypting each transcript blob (a transcript that cannot be read is reported
on stderr and makes the exit code 1). Human output is one row per hit: note
title, where (`p3` handwriting on page 3, `p3 text` a text box, `p3 math` an
equation, `p3 pdf p7`
page 7 of a PDF shown on note page 3, `rec 12:03 Title` a transcript segment
at that time) and a snippet. `--json` emits a list
of hits with `noteId`, `title`, `notebook`, `snippet`, `matches`, `source`
(`handwriting`, `text`, `math`, `pdf` or `transcript`) and per source: `page` (1-based),
`pageId`, `engine` and `words` (the recognized words containing the term with
their `[x, y, w, h]` boxes) for handwriting; `page`, `pageId`, `itemId` and `box`
(the text box's or equation's frame) for text and math; `page`, `pageId`, `itemId`, `box` (the PDF
page item's frame), `pdfPage` (1-based page of the PDF) and `engine` (what
extracted the text) for pdf; `recordingId`, `recordingTitle`, `start`,
`end` (seconds), `engine` for a transcript (no `page`). No match prints `No
matches.` (an empty list with `--json`) and exits 0. Notes are read in parallel
and without stroke geometry, as for `notes list`.

`--show-boxes` reports where each match is, as the app's "3 of 12" stepper
does: every recognized word containing a word of the term, numbered across the
note (pages in order, words in reading order). Human output adds one line per
match (`NOTE p.PAGE  N of M  WORD  [x, y, w, h]`); with `--json` every hit gains
`locations`, a list of `{n, of, text, box}` for the matches on that hit's page
(`n` counts from 1 over the whole note, `of` is the note's total). Words inside
a text box are located too (a `text` hit gets its own `locations`, each with the
box's `itemId`): the box's text is laid out with the fonts `export` draws with
and each match is the glyph extent of the matched letters, `0.8 × size` above the
baseline to `0.25 × size` below it, turned with the item (a right-to-left line
highlights the whole line). Within a page, recognized words come first, then text
boxes in drawing order; the app's highlights step through the same list.

### Handwriting recognition

```
sempere recognize (ID|TITLE... | --all) [--missing-only | --force] [--dry-run]
sempere recognize --recent [--days N]
```

Reads the handwriting of notes with Apple's Vision, on this machine (nothing
leaves it), and stores the text and word boxes as each page's recognition
(`format.md` §5.5) for `search`, `notes search` and exports. It is the app's
recognition, with the same code: the pages chosen (`RecognitionPolicy`), the
image read (`RecognitionImage`: the ink black on white, markers left out,
cropped to the ink with a 24 pt margin, at 2x or less for large ink) and the
mapping of Vision's lines and word boxes (`VisionText`). The CLI draws the
image with its own renderer where the app uses PencilKit. Each note gets one
delta of `setPageRecognition` ops, stamped with this machine's device id and
clock, and each recognition a `basis` (the digest of the strokes read), so it
is read again only when its ink changes. A note with a handwriting language
(`notes language`, `format.md` §5.4 `lang`) is read in it when Vision
supports it (the exact tag, else Vision's tags of the same language, e.g.
`es-AR` → `es-ES`, `es-MX`); otherwise Vision detects the language.

Which pages are read:

| Mode | Pages |
| --- | --- |
| default | recognition missing or out of date (ink changed since); Notability's recognition, which cannot be checked, is kept |
| `--missing-only` | only pages with ink and no recognition at all |
| `--force` | every page with ink, replacing any recognition, Notability's included |

A page whose ink is gone has its recognized text cleared (except
Notability's, unless `--force`). A page with only marker strokes gets empty
text. Deleted notes are skipped by `--all` and refused when named. `--dry-run`
lists the pages without reading or writing anything, and works on every
platform.

**macOS only.** Vision is an Apple framework; the Linux build exits 1 with a
message and changes nothing (`--dry-run` still works). Text and JSON output
list per note the pages `read` and `cleared` and the `file` written; `--json`
gives `{dryRun, notes: [{note, title, read, cleared, language, file, error}]}`
(`language`: the note's `lang`, absent when Vision detects it). A note
that cannot be read or written is reported and the exit code is 1.

Each note a run writes recognition for also gets `meta.recognized` in the
same delta (`format.md` §5.4: the time of the run, the note's page count and
how many pages were written), which puts it in the app's "Recently
Recognized" on every device for 7 days; a note found current is not written
to. `--recent` lists the notes whose `recognized` is within the last 7 days
(`--days`, 1 to 3650), newest first, whichever device's run wrote it: text
lines `ID  TIME  TITLE: read M of N page(s)`, or `--json`
`{days, notes: [{note, title, notebook, at, pages, read}]}`. It reads only
summaries, writes nothing and works on Linux. `notes show --json` gives the
register as `recognized` (`{at, pages, read}`, absent when never set).

### Handwritten math

```
sempere recognize-math ID|TITLE (--strokes ID... | --rect X,Y,W,H | --lasso "X,Y X,Y X,Y ..." | --all-ink)
                       [--page N] [--model DIR | --latex SRC | --latex-file FILE]
                       [--place replace|beside [--candidate N] [--inline] [--size PT] [--color HEX] [--dry-run]]
                       [--save-image FILE.png]
```

Reads handwritten math as LaTeX and optionally turns it into an equation: the app's "Convert to
Math", with the same code. The ink is picked with stroke ids
(or unique prefixes of 4+ characters), a rectangle or a loop of page points (a stroke is taken when
at least half of its control points are inside: `InkLasso`), or every stroke of the page
(`--all-ink`; markers' highlights are left out). It is drawn as the model wants it (`MathInkImage`:
black lines of one width, scaled into the model's input) and read on this machine by a converted
model, `--model DIR` (a `sempere-math-model/1` folder: `manifest.json`, two Core ML packages and a
tokenizer; every file is checked against its SHA-256 before anything runs; `tools/math-model/convert.py`
makes one). The model is compiled for Core ML on its first use and kept in
`$XDG_CACHE_HOME/sempere/math-models/<manifest SHA-256>` (default `~/.cache/sempere`), so later
runs load it at once and Core ML reuses its own cached build. The readings come best first, with a score (mean log-probability per token).

Without `--place` nothing is written. `--place replace` removes the strokes and adds the equation
where they were, `--place beside` keeps them and adds it to their right (or below, near the right
margin); either way it is one delta (`NoteOps.convertInk`), as tall as the ink, and has no rendering
until the app typesets it (the CLI has no typesetter, see "Equations in exports"). `--candidate`
picks another reading; `--inline`, `--size` and `--color` are `attach math`'s. `--latex` skips
recognition and converts the ink with a source made elsewhere (works on every platform).
`--save-image` writes the model's input image as a PNG (512 × 128 without a model).

**macOS only** for `--model`: Core ML exists on Apple platforms only; elsewhere the command exits 1
and changes nothing. `--json` gives `{note, page, pageId, strokes, engine, seconds, candidates:
[{latex, score}], placement, dryRun, file, item, removed, image}`.

### Transcription

```
sempere transcribe (ID|TITLE [RECORDING...] | --all) [--language TAG] [--engine auto|speechtranscriber|sfspeech]
                   [--force] [--dry-run] [--no-download]
sempere transcribe --check [--language TAG]
sempere transcribe --download-model [--language TAG]
```

Transcribes a note's recordings on this machine with Apple's Speech framework
and stores each transcript (`format.md` §8.3.2: time-stamped segments, every
word with its time and confidence, the language and the engine) as a blob of
the note, then sets it on the recording: one delta of `setRecording` ops per
note, stamped with this machine's device id and clock. It is the app's
engine, with the same code (`SpeechTranscription`, `Sources/SempereSpeech`):

| Engine | When | Notes |
| --- | --- | --- |
| `speechtranscriber` | macOS 26 and later | SpeechAnalyzer with SpeechTranscriber, long-form, word times and confidence; the on-device model for the language is installed on first use (Apple's asset service; `--no-download` refuses instead) |
| `sfspeech` | fallback | `SFSpeechRecognizer` with `requiresOnDeviceRecognition`; needs the speech recognition permission, which a command-line program cannot ask for, so from the CLI it works only once that permission was granted |

Nothing is ever sent to a server: a language without an on-device model is an
error. The language is `--language`, else the note's language (`format.md`
§5.4 `lang`), else this machine's; it is matched to a
supported one (the same tag, else the same language with this machine's
region, else the first of that language). Each recording's audio is decrypted
into a private temporary file (mode 0600) for the recognizer and deleted
afterwards.

By default only recordings without a transcript are read; recordings named on
the command line (id, id prefix of 4+ characters, or exact title) are read
whatever they have, and `--force` replaces every transcript. `--dry-run` lists
what would be read and works on every platform. `--check` prints which engines
can transcribe here, for which language, and needs no vault (`--json` gives `{supported, engines: [{engine,
available, language, detail}]}`). `--download-model` installs
SpeechTranscriber's on-device model for the language (`--language`, else this
machine's) through Apple's asset service, without a vault, and returns when it
is installed (at once if it already is); it is what the app's Settings ▸
Transcription ▸ Download Language Model button runs. It stands alone (`--check`,
`--dry-run`, `--all` and a note are usage errors) and exits 1 where there is no
Speech framework or no such model. The SFSpeechRecognizer fallback has no
downloadable model.

**macOS only.** The Linux build exits 1 with a message and changes nothing
(`--dry-run` and `--check` still work). `--json` gives `{dryRun, notes: [{note,
title, file, error, recordings: [{id, title, engine, language, segments, words,
transcript, error}]}]}`; a recording that cannot be transcribed is reported
and the exit code is 1.

### Quick capture inbox

```
sempere inbox enable [--notebook NAME] [--profile PATH]          (needs the key once)
sempere inbox capture FILE [--title T] [--started TIME] [--type MEDIA] [--transcript JSON] [--profile PATH]
sempere inbox transcript CAPTURE JSON --audio FILE [--profile PATH]
sempere inbox list
sempere inbox import [CAPTURE...] [--dry-run] [--retry]          (needs the key)
```

Voice notes without the key (`format.md` §11, `docs/quick-capture.md`), the
same path as the app's widgets, Control Center control, Action button, Mac menu-bar item and Siri. `enable`
writes this machine's **capture profile** (the vault identity's public key and
the device capture key of the device it was unlocked as, which can only add
captures and never reads anything) to
`$XDG_STATE_HOME/sempere/capture/<vault id>.json`, mode 0600. It needs a
listed device's key (not the recovery key). Captures are
**attributed** to that device (`format.md` §11.1): another machine's
profile cannot seal one that passes as this one's. Run it again after the
vault starts a new epoch (a device removed or another change, Devices, "New epochs": that changes the
capture key). It refuses (exit
6) a device list that does not check (`format.md` §2.1), so a profile is only
ever made from a checked one. `capture` reads
only `vault.json` and the profile, no identity or passphrase. It seals the
audio file into `inbox/<id>.capture.age` (encrypted to the vault identity, tagged
with the capture key) and prints the capture id. When this machine's device key
is stored without a passphrase, each file is first recorded in its write ledger
(Devices, "New epochs"), so a capture sealed with a profile of an earlier epoch
is re-sealed under the current key by `vault catch-up` (or the next write); else
such a capture stays set aside. `--transcript` seals a
`sempere-transcript/1` file with it, and `transcript` seals one later; either
way its recording id is replaced by the capture's, and it is bound to the
capture's audio (`format.md` §11.2): `transcript` needs that audio file
(`--audio`, the bytes that were captured), and a transcript bound to other
audio is never adopted, nor is one sealed by another device than its
capture's. Both refuse (exit 7) a vault of a newer format. `list` shows the inbox:
ids and file kinds without a key, with one the titles, whether each verifies
and who captured it (`from iPad (device 0b0b0b0b)`, with the device's name
in `vault.json`, or `from a device no longer in this vault (…)`).
A capture sealed by a device that is no longer in the vault never verifies:
it is reported and kept.
`import` adopts each capture as a note in the capture's notebook ("Inbox"),
titled from its date: the audio and transcript as blobs, then one delta as this
machine (the note's page shows the recording's card, where its transcript reads, as a recording made
in a note does) (the recording records who captured it, `captured`, `format.md`
§8.3.1), then the inbox files are deleted. The note, page and recording ids
derive from the capture id, so importing on two machines gives one note. A
capture that does not verify is reported (exit 1) and kept. Each file's tag
is checked as it is decrypted, before the file is read whole, and a
`transcript` file over about 64 MiB is refused from its size. A file that
failed is recorded in `$XDG_STATE_HOME/sempere/inbox-backoff.json` and not
read again for an hour, then twice as long after each failure (up to a
week), while it does not change: `import` reports it as `failed N time(s)
…; not read again before TIME`. Naming the capture, or `--retry`, reads it
now. `--json`:
`enable` gives `{profile, device, notebook, recipient}`; `capture` gives
`{capture, note, files}`; `list` gives `[{capture, kinds, title, started,
duration, device, recipient, capturedBy, error}]` (`recipient` is the
fingerprint of the key the capture is attributed to, `capturedBy` its device's name);
`import` gives `{dryRun, captures: [{capture, note, title, created,
transcript, card, file, removed, error, captured, capturedBy}]}` (`card`: the new note shows the
recording's card on its page).

### Shared settings

```
sempere settings list     [--type mac|ipad|iphone] [--all]
sempere settings get      KEY [--type T]
sempere settings set      KEY VALUE [--type T]
sempere settings reset    KEY [--type T]
sempere settings edit
sempere settings validate
sempere settings schema
```

The vault's shared settings, `settings.age` (`format.md` §13,
`docs/settings-sync.md`): what devices with Settings ▸ Sync Settings with This
Vault on follow. Keys are flat and dotted (`editor.defaultPaper`,
`mouse.smoothing`); each is listed once with the device types that use it
(`docs/settings-sync.md` §5). A key may also hold a value for one kind of device
in a type block, `[mac]`, `[ipad]` or `[iphone]`; `--type` targets that block. A
device resolves a setting from its type block, then the top level, then the
built-in default. **The CLI has no device overrides**: "Only on This Device"
lives on each device and wins there over anything set here.

- `list` shows every known key with its value and where it comes from (`top`,
  `block` or `default`); with `--type`, what a device of that type uses (only the
  keys it uses); `--all` adds unknown keys and every type block's entries.
- `get` prints one value as JSON (resolved for `--type`); a key this version does
  not know prints its raw value.
- `set` validates the value against the registry: `true`/`false`/`on`/`off` for
  switches, numbers and names from the key's list, a title pattern as `notes new
  --title-format` checks it, a notebook path (stored canonical), a paper kind
  (`ruled`, `grid`, …) or a paper JSON object (clamped), `null` (or `device`) for
  the device's transcription language. Unknown keys are refused (exit 2).
- `reset` writes a reset (the default applies; with `--type`, the top level
  applies again on that kind of device). Resets merge like values, so a device
  still holding the old value does not bring it back.
- `edit` opens `$VISUAL`, `$EDITOR` or `vi` on the decrypted JSON without `$meta`
  (mode 0600 in a private 0700 temporary folder, deleted afterwards). The result
  must be a settings object with both versions and valid values for every known
  key, without `$meta`; otherwise nothing is written (exit 1). Each changed key
  is recorded in `$meta` and merged with what other devices wrote.
- `validate` checks the file against the schema: invalid values of known keys,
  malformed `$meta` entries or versions, and a `$minReaderVersion` newer than
  this version are errors (exit 3); unknown keys, blocks and `$` members are
  information. A vault without the file is valid.
- `schema` prints the JSON Schema (`docs/settings.schema.json`) made from this
  version's registry.

Writes merge per key with the file on disk (last writer wins, `format.md`
§13.3), keep everything this version does not know, record no device type, and
are refused like every write: exit 6 for an untrusted device
list, 7 for a read-only vault. A file whose `$minReaderVersion` is newer than this
version is refused by every command but `validate` (exit 7) and never rewritten.
`--json`: `list` gives `{schemaVersion, minReaderVersion, type, settings: [{key,
value, source, defaultValue, usedBy, summary}], others: [{key, block, value,
known}]}`; `get` gives `{key, value, source}`; `set` and `reset` give `{key, value,
block}`; `edit` gives `{changed}`; `validate` gives `{valid, issues: [{severity,
path, message}]}`.

### Export

```
sempere export (ID|TITLE | --all) --format pdf|svg|png|json|markdown|html|media --out PATH
                [--merge] [--deleted] [--no-paper] [--dpi N] [--at REVISION] [--breaks gaps|fixed]
                [--notebook NAME] [--images none|png] [--clean]
                [--pdf-renderer auto|poppler|none] [--pdf-timeout SECONDS]
                [--assets DIR] [--keep-image-metadata] [--recordings none|attach|list]
                [--videos none|attach] [--attachments]
                [--layout flat|notebooks] [--zip] [--overwrite] [--no-cache]
```

- `--at REVISION` (single note only) exports the note as it was at that
  revision, named as for `notes restore --to`.
- Exports are plaintext, so they are written for their owner only, whatever the umask: files mode 0600
  (written under a temporary name and renamed), folders the command creates 0700. A folder that already
  exists keeps its mode. `--zip` stages the files in a fresh 0700 folder of its own in the temporary
  directory (deleted when the run ends) and writes the archive 0600.

- `pdf`: one file per note; `--merge` puts every selected note in one PDF
  (`--out` is then the file). A paged note gives one PDF page per page (plus,
  rarely, pages for ink a concurrent edit left below a page). A pageless page
  is cut into pages of its sheet height (`breakHeight`, else width × 11/8.5);
  with `--breaks gaps` (the default) a cut that would cross ink moves up, by
  at most a quarter page, to the top of that ink, so lines of handwriting are
  not cut in half; `--breaks fixed` cuts at every sheet height
  (`docs/format.md` §5.4.3, "Exporting"). Cornell paper is always cut at
  sheets.
- `svg`: one file per page (a pageless page is one tall image). A single note gives `<name>-p001.svg`,
  `<name>-p002.svg`, ... in the output directory; with `--all` each note gets a
  subdirectory, `<name>/p001.svg`, `<name>/p002.svg`, ...
- `png`: one RGBA8 image per page, written like `svg` (`<name>-p001.png`, ...,
  or `<name>/p001.png` with `--all`). Pure Swift, no system imaging library.
  Paper, strokes and tool opacity match the PDF; edges are anti-aliased. An
  infinite page is split into images exactly as it is split into PDF pages
  (`--breaks` applies); the number is the note page's, and the further images
  of a split page add `-2`, `-3`, ... (`p001.png`, `p001-2.png`, `p002.png`),
  as everywhere PNG pages are written. `--dpi N` sets the resolution (default 144,
  i.e. 2x the 72 pt/inch page; `0 < N <= 2400`, else exit 2). An image over
  40 million pixels (a letter page above about 620 dpi) is an error naming the
  limit, not an allocation; lower `--dpi`. With `--no-paper` the background is
  transparent.
- `json`: the reconstructed note (`NoteState`, `docs/format.md` §6), items and recordings included.
- `media`: the note's recordings (and their transcripts as `.txt`), video clips, images and PDFs as
  files in a folder `<name>/` under `--out`, with `media.json` (see "Media export" below).

Every item kind is drawn by `pdf`, `svg` and `png`: text boxes (bundled fonts and font packs, "Text in
exports"), images ("Images in exports") and PDF pages ("PDF page backgrounds"), from the
note's own blobs. Pages never show recordings. `--recordings attach` (PDF only; the app's "PDF +
attachments") embeds each note's recordings as PDF file attachments (`/Names /EmbeddedFiles`,
PDF 1.4: the audio byte for byte, named after the recording's title, and its transcript as a
`.txt` of time-stamped lines); viewers list them and play or save them (`pdfdetach -list`
shows them). At most 512 MiB of recordings go into one PDF; the rest are left out with a
warning. Without it (`none`, the default) a PDF export warns "N recordings not exported".

A PDF that embeds anything (`--attachments`, `--recordings attach`, `--videos attach`) ends with
the **attachment list**: a page (or more) with one row per recording, embedded transcript and
video clip (kind, title, the PDF pages it appears on, duration, size), a paperclip link
(FileAttachment annotation) to each embedded file and a link to the first page it appears on;
one left out is marked "(not embedded)". `--recordings list` adds the page without embedding
anything; `--recordings list,attach` is the same as `attach`. A note without recordings or clips
gets no page. `pdfdetach -list` shows each embedded file twice (the document's list and the
link), stored once. docs/io.md "The attachment list page".

Video clips (`format.md` §8.2.7) are drawn by `pdf`, `svg` and `png` as their poster, stretched
onto the frame, with a play mark over it (a disc and a triangle); a video without a poster is a
crossed-out box with the mark, reported as "video without a poster frame". `--videos attach` (PDF
only) embeds each note's clips as PDF file attachments, each once however often it is placed,
named `<title> – Video N.mp4` (or `.mov`), byte for byte as stored; `--attachments` embeds
recordings and videos (the app's "PDF + attachments"). The PDF is written to a temporary file
next to `--out` and moved into place, and the clips are **streamed** from the vault into it:
memory does not grow with them, and up to 8 GiB of attachments go into one PDF. A clip that is
missing or not yet downloaded is left out with a warning; one that fails verification while it
is written fails that note's export (nothing is left behind). Without it a PDF export warns "N
video clips shown as poster only".

- `markdown` and `html`: a folder tree, see "Markdown and HTML exports" below.
  `--notebook NAME` (with `--all`, any format) keeps only notes in that
  notebook or below it (whole segments, case-sensitive, `NotebookPath`).

File names are the sanitized title plus the first 8 characters of the note id
(`Physics-Week-3-0d1c6a1e.pdf`). `--out` is a directory (created if needed),
except that a single note's pdf/json goes to the file when `--out` ends in
`.pdf`/`.json`. `--all` skips deleted notes unless `--deleted`; a deleted note
named explicitly is exported with a warning. One note that fails to
reconstruct does not stop the others; the exit code is then 1. Every file
written is printed. With `--json`, each entry has `note`, `files` and, when
some items were drawn as placeholders, `placeholders` (their number),
`recordings` and `videos` (the numbers embedded) with `--recordings attach` and `--videos attach`, and in a bulk
export (below) `skipped` (`true` for a note left as an earlier run wrote it); the Markdown and HTML exports
add `changed` (see "Re-export").

#### Media export

`--format media` writes each note's attachments as files into `--out/<name>/`, decrypted and
verified (streamed, never held whole), each blob once however often it is placed:

```
Physics-Week-3-0d1c6a1e/
  Physics-Week-3-Recording-1-Lecture.m4a     the audio as stored
  Physics-Week-3-Recording-1-Lecture.txt     its transcript, "[m:ss] text" lines
  Physics-Week-3-Video-1.mp4                 location metadata removed (--keep-image-metadata keeps it)
  Physics-Week-3-Image-1.jpg                 JPEG/PNG metadata removed (likewise; other images as stored)
  Physics-Week-3-PDF-1.pdf                   the PDF behind the note's PDF pages, as stored
  media.json
```

`media.json`: `{"format": "sempere-media/1", "note": ID, "title": …, "files": [{"file", "kind"
(recording, video, image, pdf), "title" (a recording's), "pages" (1-based note pages it appears
on), "duration", "started" (a recording's, RFC 3339), "transcript" (the .txt), "type", "size"}]}`.
Recordings come first in their order, then clips, images and PDFs in page order. A blob that is
missing or not downloaded, a transcript that cannot be read, and a JPEG or PNG that cannot be parsed
to remove its metadata are left out with a warning; other images (a HEIC kept as taken) and JPEG/PNG
over 64 MiB are written as stored, metadata included, with a warning; a blob that fails
verification fails the note (exit 1, nothing of it left behind). A note without media writes nothing and warns "no media: no recordings, videos,
images or PDFs to export" (exit 0, and an `--out` folder the command would have created is not left behind). With `--json`, `files` lists the files written, `media.json`
last. `--no-paper`, `--breaks`, `--merge`, `--images` and `--recordings` do not apply (exit 2).
With `--all` it is a bulk export (below): `--layout`, `--zip` and resuming apply, and notes whose
summary names no audio, video, image or PDF are skipped without being read.

#### Bulk export

`--all` with `--format pdf`, `png` or `media` (not `--merge` or `--at`) runs the bulk
export the app's "Export to Folder or Zip…" uses (`BulkExportSession`, docs/io.md "Bulk
export"): notes are planned from the summaries (the summary cache unless
`--no-cache`), then read, rendered and written **one at a time**, so memory is
that of the largest note, not of the vault.

- `--layout notebooks` puts each note in a folder per notebook level
  (`School/Math/Week-1-0d1c6a1e.pdf`); with `--notebook NAME` the folders
  start at that notebook (`Math/…`), as the app's "Export Notebook…". The
  default, `flat`, writes every note directly in `--out`.
- `--zip`: `--out` is a zip archive (stored entries, zip64 when needed) holding
  the same tree; notes are staged in the temporary directory one at a time.
- Names: two notes whose names would clash in a folder (same title and id
  prefix, equal ignoring case or Unicode normalization, or equal to a
  sub-folder) take the full id, then `-2`, ...
- **Re-runs skip unchanged notes.** `--out` gets a hidden
  `.sempere-export-bulk.json` listing each file with its note, the note's
  version (a fingerprint of its revision file names), the options and the size.
  Exporting again into the same folder skips a note whose files are all still
  there with the same names and sizes, for the same note version and options
  (printed as `Unchanged …`, and `"skipped": true` with `--json`); the summary
  line says how many. `--overwrite` renders every note again. A zip is
  always written whole.
- A note that cannot be read or rendered is reported on stderr and the others
  are exported; the exit code is then 1.
- `--recordings attach` without `--videos attach` (or the reverse), and
  `--recordings list`, use the in-memory path; `--attachments` (both) is
  the bulk "PDF + attachments".

The app's sheet shows the matching command for a notebook or the whole vault:

| App ("Export to Folder or Zip…") | `sempere export` |
| --- | --- |
| All notes, PDF, folders like notebooks, into a folder | `--all --format pdf --layout notebooks --out FOLDER` |
| Notebook "School/Math", PDF + attachments, zip | `--all --notebook School/Math --format pdf --attachments --layout notebooks --zip --out Math.zip` |
| All notes, PNG at 300 dpi, no paper, flat | `--all --format png --dpi 300 --no-paper --out FOLDER` |
| All notes, Media, folders like notebooks | `--all --format media --layout notebooks --out FOLDER` |
| A list selection | one `sempere export ID --format pdf --out FOLDER` per note |

#### PDF page backgrounds

A `pdfPage` item (an annotated PDF, `docs/format.md` §8.2.6) is read from the
note's attachments, verified (`docs/format.md` §8.1.4), and drawn under the ink:

- `pdf` copies the original page into the export as a Form XObject: exact
  vectors, text and images, on every platform, with no renderer. The file is
  PDF 1.7 when it holds such pages. Only the page's content and resources are
  copied (annotations, form fields and metadata are not). A page whose content
  uses a stream filter the reader does not decode (anything but Flate, LZW,
  ASCII85, ASCIIHex and RunLength) is rasterized by the renderer below, or is a
  placeholder.
- `svg` and `png` need the page as pixels. `--pdf-renderer auto` (the default)
  uses Poppler's `pdftoppm` when it is installed (`$SEMPERE_PDFTOPPM`, else
  `pdftoppm` on `PATH`; `apt install poppler-utils`, `brew install poppler`);
  `poppler` requires it (exit 1 when it is missing); `none` never runs it. SVG
  embeds the page as a PNG data URI clipped to the item's frame (at 2 pixels
  per drawn point); PNG composites it at `--dpi`. A page is drawn with at most
  16 million pixels, and one export rasterizes at most 256 million.
- Poppler runs as a separate process on a private temporary copy of the
  verified PDF (deleted afterwards), started with an argument vector (never a
  shell) and under resource limits: `--pdf-timeout` seconds of wall-clock time
  per page (default 30, more than 0 and at most 3600; then SIGTERM, then SIGKILL), as much CPU time, 3 GiB
  of address space where the OS enforces it, an output file no larger than the
  requested pixels need, no core dumps. A PDF that makes Poppler hang, crash
  or write garbage costs at most one timeout and becomes a placeholder.
- Anything that cannot be drawn (no renderer, a missing or invalid
  attachment, an unreadable or encrypted PDF, a failed render, an item kind
  this export does not draw yet) is a placeholder: the item's frame outlined in
  gray with both diagonals (`docs/format.md` §8.5.2). The export still
  succeeds (exit 0) and prints one warning per kind of problem, e.g.

  ```
  sempere: warning: 0d1c6a1e: 12 PDF background pages drawn as placeholders: install poppler (pdftoppm) to render them, or export as PDF, which keeps them exactly
  sempere: warning: 0d1c6a1e: pdfPage item drawn as a placeholder (PDF renderer failed: pdftoppm timed out after 30 s)
  ```

`markdown` draws `pdfPage` items in its PDF (and per-page PNGs), `html` in its
SVG pages, as above.

#### Images in exports

Image items (`docs/format.md` §8.2.5) are drawn from the note's attachments
(`notes/<id>/att/`), each blob decrypted and checked against its reference
(§8.1.4) before use. Placement follows §8.5.1 (EXIF orientation, crop, frame,
rotation); images are clipped to their frame, under the ink.

- `pdf`: a JPEG is embedded as stored (`DCTDecode`, never re-encoded); PNG
  (and anything else decoded) as lossless 8-bit RGB or gray with a soft mask
  for transparency. One copy per image however many pages use it.
- `svg`: each image as a `data:` URI. `--assets DIR` (svg only) writes each
  image once into `DIR` instead (named by a hash of its bytes, `.jpg`/`.png`)
  and links it with a path relative to the SVG files.
- `png`: images are decoded and resampled into the page (a JPEG decoded at
  1/2, 1/4 or 1/8 size when that is all the output needs).
- **Metadata:** location and camera data (JPEG APPn segments other than JFIF,
  ICC and Adobe; COM; PNG text, `eXIf` and other ancillary chunks; anything
  after the image's end) is removed from every image an export carries,
  whatever is stored, unless `--keep-image-metadata`.
- **Placeholders:** an item that cannot be drawn is a crossed-out gray box
  (§8.5.2) and a warning on stderr, as for PDF pages above, e.g.
  `sempere: warning: 0d1c6a1e: image item drawn as a placeholder (HEIC images
  cannot be decoded here (convert it to JPEG in the app))`. Causes: a missing, unreadable or
  damaged attachment; HEIC (the CLI has no HEVC decoder; the app exports it);
  CMYK, 12-bit, lossless or arithmetic-coded JPEG; an image over 100
  megapixels (§8.4) or over 64 MiB; unknown item kinds. The export still
  succeeds; with `--json` each note's `placeholders` counts them. `markdown`
  and `html` exports draw images too.

#### Equations in exports

Equations (`math` items, `docs/format.md` §8.2.8) are drawn from their stored
rendering, a one-page PDF the app (or `attach math --render`) wrote: `pdf`
copies it as a Form XObject (exact vectors, transparent around the marks);
`svg` and `png` rasterize it with Poppler as for PDF pages above and turn the
white page back into coverage of the equation's color, so the paper shows
around it. An equation without a rendering (written by `attach math` alone),
or whose rendering cannot be drawn (missing, damaged, no Poppler for SVG or
PNG), is drawn as its LaTeX source in a monospace font at its size and color,
with one warning per equation:

```
sempere: warning: 0d1c6a1e: page 1: equation 5e2b9c1d is drawn as its LaTeX source (no typeset rendering stored; typeset it in the app)
```

Only when the source cannot be laid out either is it a placeholder. `markdown`
and `html` exports also list each page's equations as `$$source$$` (display)
or `$source$` (inline) text.

#### Text in exports

Text boxes (`docs/format.md` §8.2.4) are laid out as §8.5.3 says: on the lines
the writer stored (`breaks`), else broken by the Unicode line breaking
algorithm (UAX #14) to the frame width; each line is reordered for right-to-left
text (UAX #9) and aligned; every line sits at the same height on every renderer.

- **Fonts.** The CLI ships Noto Sans, Noto Serif and Noto Sans Mono (Latin,
  Greek, Cyrillic; regular, bold, italic, bold italic) under the SIL Open Font
  License 1.1, as files next to the program (`fonts/` in the release archive,
  `share/sempere/fonts` with Homebrew; `$SEMPERE_BUNDLED_FONTS` overrides).
  Other scripts come from **font packs**: any `.ttf`, `.otf`, `.ttc` under
  `$SEMPERE_FONT_DIR`, `$XDG_DATA_HOME/sempere/fonts` (default
  `~/.local/share/sempere/fonts`) and the system font directories
  (`/usr/share/fonts`, `/usr/local/share/fonts`, `~/.fonts`,
  `~/.local/share/fonts`, and on macOS `/Library/Fonts`,
  `/System/Library/Fonts`, `~/Library/Fonts`), searched in that order and only
  when a character needs them. The box's `lang` (or a run's) picks among
  Chinese, Japanese and Korean faces (`ja` → JP, `ko` → KR, `zh-Hant` → TC,
  `zh-HK` → HK, other `zh` → SC). On Debian or Ubuntu, `fonts-noto-cjk` and
  `fonts-noto-core` cover nearly every script.
- **Shaping.** Arabic and other joining scripts get their initial, medial,
  final and isolated forms and required ligatures; Hebrew and Arabic marks are
  attached to their letters. Scripts that need a full shaping engine (Indic
  conjuncts, Khmer, Myanmar, ...) are drawn unshaped with a warning that they
  are approximate (the app's exports of the same note are exact).
- **PDF** embeds, per font used, a subset with exactly the glyphs drawn
  (`ABCDEF+Name`, Type0 / CIDFontType2 or CIDFontType0C) and a `ToUnicode`
  map, so text can be searched and copied (`pdftotext` extracts it).
- **SVG** embeds the same subsets as `@font-face` data URIs. The visible
  glyphs are addressed through private-use code points, so every viewer draws
  exactly the shaped glyphs; an invisible `<text>` per line over them holds the
  real characters for selection, search and copying.
- **PNG** fills the glyph outlines.
- **Missing scripts.** A character no available font covers is drawn as the
  missing-glyph box and reported, naming the script and what to install, e.g.
  `sempere: warning: 0d1c6a1e: page 2: item 6f1c2d4e: text uses Han (Chinese,
  Japanese, Korean) characters (e.g. 汉, U+6C49); no installed font covers
  them, so they are drawn as boxes (install fonts-noto-cjk or put a font in
  ~/.local/share/sempere/fonts or $SEMPERE_FONT_DIR)`.
- A text box that cannot be laid out (no `RenderOptions.shaper`
  given) is a placeholder, reported like any other.

#### Markdown and HTML exports

> **These formats write your notes as PLAINTEXT.** The vault is end-to-end
> encrypted; `--format markdown|html` decrypts it into ordinary files (text,
> PDF, PNG, SVG) that anyone with access to the folder can read, and that
> cloud-sync or backup tools will copy. Choose the output folder accordingly
> (an encrypted volume, not a synced public folder). Nothing is encrypted again.

`--out` is always a directory. Notebooks mirror as folders: the notebook
`School/Math` (`format.md` §5.4) is `School/Math/`; each segment is sanitized
like a file name (`ExportName.component`) and names that differ only by case
share one folder. Notes without a notebook sit in the root. File names are
`ExportName.stem` (title + 8 id characters), so two notes with the same title
never collide; for markdown `[ ] # ^` in the stem also become `-` (they break
Obsidian wikilinks). A segment or stem is at most 120 UTF-8 bytes (file names are
limited in bytes, not characters); a notebook folder named like a Windows device
(`CON`, `NUL`, `COM1`, ...) or like an index file the export writes (`README.md`,
`index.html`) gets a `_` appended. The `.sempere-export-<format>.json` manifest is
not trusted: entries that would leave `--out` are ignored, so a doctored one in a
shared folder cannot make an export write or `--clean` delete elsewhere.

`--format markdown` writes, per note:

- `<stem>.md`: YAML front matter, then the PDF, then one section per page that
  has an image or recognized text. Front matter keys: `title`, `id`, `created`,
  `modified` (UTC, `...Z`; `modified` is the newest revision's wall time),
  `tags` (a list; `[]` when none; Obsidian-safe: `#` dropped, whitespace
  becomes `-`, case-insensitive duplicates merged), `notebook` (canonical
  path, omitted when none), `favorite` (only when true), `pages`, `source`
  (`sempere:<vault id>`). Every string is a double-quoted YAML scalar with
  `"` `\` newlines, control characters and U+0085/U+2028/U+2029 escaped; other
  Unicode is kept as is.
- `<stem>.pdf` (the PDF writer), embedded as `![[<stem>.pdf]]` and linked as a
  standard Markdown link.
- With `--images png`: `<stem>-assets/p001.png`, ... (the PNG writer, `--dpi`
  and `--no-paper` apply; a page that spans several images adds
  `p001-2.png`, ...), embedded as `![Page N](...)` under `## Page N`.
- Recognized text (`format.md` §5.5), when a page has it, under that page as
  `Machine-recognized text (engine ..., may contain errors):` followed by a
  fenced `text` block, so it stays literal and Obsidian or `grep` finds it.
- The text of the page's text boxes, in drawing order, under `Typed text:` as
  fenced `text` blocks (a page with only typed text gets a section too).
- Video clips: each clip once, streamed from the vault to
  `<stem>-assets/video-1.mp4`, `video-2.mov`, ... (in page and drawing order), with its
  location and device metadata blanked unless `--keep-image-metadata`, embedded under its page as
  `![[<stem>-assets/video-1.mp4]]` and linked as `[Video 1 (0:42)](...)`. The note's PDF draws
  the posters; it does not embed the clips.
- `README.md` in the root and every folder: sub-notebooks and notes (title,
  pages, modified, tags). These list every note the output folder has been
  exported with, not only this run's.

`--format html` writes one self-contained `<stem>.html` per note (inline SVG
pages from the SVG writer, with the text fonts and images of all pages defined once in a hidden
`<svg>` at the top of the page; light and dark CSS; title, notebook, dates and
tags; a link back to the index) and `index.html`: notes grouped by notebook
and a search box filtering as you type over title, notebook, tags and
recognized text, ignoring case, accents and width as the app's search does (a few lines of inline script; the page works without it,
unfiltered). Recognized words are also laid over the ink as an invisible
selectable SVG text layer, and each page's text is listed below it in a
collapsed "Machine-recognized text" block, and the text of its text boxes in a
collapsed "Typed text" block; the index search covers both. Video clips are written next to
the page as for Markdown (`<stem>-assets/video-N.mp4`) and shown under their page with a
`<video controls preload="none">` and a link. Apart from those clip files there are no external resources:
no scripts, fonts, stylesheets or images are fetched, and the file is
well-formed XML as well as HTML.

**Re-export.** Each file is rewritten only if its content would change
(`Wrote ...` lists those; the last line counts written and unchanged files), so
re-running is cheap for sync tools and keeps timestamps. The export records
what it wrote in `.sempere-export-<format>.json` in `--out`. Renamed, moved or
deleted notes leave their old files until `--clean` (needs `--all`): it removes
files recorded there that this run did not produce (restricted to the
`--notebook` filter, if any), and the folders that leaves empty. It never
touches files it did not write. A note that fails to export keeps its old files.
`--json` lists `note`, `files` and `changed` per note.

An unchanged note is not even read: the manifest also records, per note, a key made of its
revision file names, the options, the PDF renderer and its timeout, the fonts available to the program (its version, a hash of the program itself and the render-output version), the
note's attachment files, its file name and the vault, together with the files written, their sizes and times (and a content hash, so a same-length edit of a file is noticed and put right). A note whose key is the same and whose files are all still there at that size is left
alone (its files count as unchanged and survive `--clean`), so a second run of an unchanged
vault takes a listing, not a render. Notes are read one at a time as they are rendered. (A
skipped note reports no placeholder warnings; they were printed when it was rendered.)

### Recover

```
sempere recover FILE.age [--note-id UUID] [--identity FILE ... | --recovery-key FILE] [--vault PATH] [--no-verify]
```

Every vault file is encrypted to the vault identity (`format.md` §3.1). The
key is either the vault keys the kit's script prints (`--identity
vault-keys.txt`, `format.md` §15.13), which open any file on their own, or a
key the vault lists (this machine's device key, `--identity FILE`, or
`--recovery-key FILE`), which opens the file through the vault's
`vault.json` (so the vault must be known, below). Without either it exits 4.

Given an attachment blob (`notes/<id>/att/<name>.<kind>.age`) it prints the
blob's content, byte for byte what
`age -d -i vault-keys.txt FILE | tail -c +46 | head -c LEN` prints (`format.md` §8.1.7).
Framing, zero padding and the content hash are always checked; the file name
too when a vault is known (a name that does not verify: exit 1, nothing
printed); otherwise `UNVERIFIED NAME: ...` goes to stderr. Content streams as
it is decrypted: if the command fails midway, discard the output.

Decrypts one revision file and prints its JSON to stdout, byte for byte what
`age -d -i vault-keys.txt FILE | tail -c +38 | gunzip` prints. With the vault
keys it needs only that file and the one `.age` file. If a vault is known (`--vault`, else `vault.json`
found in a parent directory of the file, else `$SEMPERE_VAULT`) and the key
opens it, the inner HMAC tag is verified (the note id is the
file's directory name unless `--note-id` says otherwise); otherwise
`UNVERIFIED: ...` is printed to stderr and the JSON is printed anyway. A tag
that does not match is an error (exit 1, nothing printed; the message points to
`--no-verify`). `--no-verify` is for damaged vaults: on a mismatch it prints the
body anyway, writes `WARNING: tag mismatch, content may be tampered or from
another vault` to stderr and exits 3 so scripts can tell. Wrong key: exit 4.

### Maintenance

```
sempere compact (ID|TITLE | --all) [--retention DAYS | --thin-older-than AGE | --thin-all] [--dry-run] [--no-cache]
sempere snapshot ID|TITLE
```

`compact` deletes only what a snapshot makes redundant and what is older than
`--retention` days (default 30), per `docs/format.md` §5.3. When a note has
deltas past the retention window that no snapshot covers (always the case for a
note with no snapshot, once it has anything that old), it
writes a snapshot first (device id and clock as for `snapshot`), then compacts.
`--dry-run` writes and deletes nothing and lists `would snapshot` and
`would delete` lines. With `--all` a note that cannot be compacted (an unreadable
revision) is reported on stderr, the other notes are still processed, and the
exit code is 1.

Checkpoints (`notes checkpoint`) are never deleted, and each one stays a
complete restore point with the same content: when the revisions a checkpoint
depends on are deleted, `compact` first writes a snapshot *as of* the
checkpoint (`asOf`, `docs/format.md` §5.8.3) and keeps one revision per other
device just after it (a *witness*, §5.8.4 rule 3).

`--thin-older-than AGE` thins instead (`docs/format.md` §5.8.4): `AGE` is days,
as `30d` or `30` (more than 0), or `never` (do nothing). Among the revisions
older than that (the longest run from the oldest revision whose wall times are
all older), it keeps every checkpoint, the newest autosave of each editing
session (the groups of `notes history --sessions`) and the note's newest
revision, and deletes the rest, deltas and snapshots alike. Every kept version
and every newer revision stays a complete restore point with the same content,
and the note's current state is unchanged; to make that so it writes a snapshot
as of each kept version that needs one, before deleting anything. Each of those
is a full copy of the note, so thinning can add bytes while it removes files:
the output says how many it deletes and adds (`Would delete 12 file(s), 48.0 KB;
would add 2 snapshot(s), 310.5 KB.`), with `would snapshot NOTE (as of
REVISION)` lines. Thinning twice with the same age does nothing the second
time. Before the per-file lines it prints the rule it applies and what it keeps
(`Thin versions older than 30 days (dry run). Removes autosaves older than 30
days. Keeps every checkpoint …`).

`--thin-all` is "thin everything except checkpoints" (`docs/format.md` §5.8.4):
no age window and no session ends, so every autosave goes, however recent;
every checkpoint (saved versions and imports, §5.8.1) and the note's newest
version stay (plus the few revisions the rules keep for ordering, §5.8.4 rule 3). It prints its own rule line. `--retention`, `--thin-older-than` and
`--thin-all` are different modes; give one.

Thinning and compaction decide from each revision's metadata (names, wall
times, checkpoint and session fields, snapshot coverage) which notes have
anything to delete, and read only those in full; that metadata comes from the
summary cache (`docs/format.md` §10, filled by listings; `--no-cache` reads
every note instead). A note the cache does not know is decrypted once: its
metadata, and the whole note only when something may go, come from the same
read. Notes are read, planned and carried out in parallel.

`--json` emits one object per note: `note`, `snapshotNeeded`, `snapshot` (the
first snapshot written; null on a dry run), `snapshots` (each `{file, asOf}`;
`file` null on a dry run, `asOf` set for a positioned snapshot), `files` (the
revisions deleted, or that would be), `witnesses`, `bytesDeleted` and
`bytesAdded`.

`snapshot` writes a snapshot of the note. Both need a
key. Snapshots stamp the file with this machine's
device id and clock from `$XDG_STATE_HOME/sempere/device.json` (default
`~/.local/state/sempere/device.json`), created on first use:

```json
{ "device": "3fa9c01e", "millis": 1760000000000, "counter": 0 }
```

### Sync

```
sempere sync webdav URL --vault V [--user U --password-env VAR] [--device NAME]
                         [--max-blob-mib N] [--web-viewer] [--dry-run] [--json] [--identity FILE | --passphrase-env VAR]
                         [--push-only [--delete-extraneous] [--keep-server-changes]] [--retry-quarantined]
                         [--skip-unchanged] [--no-deep-listing] [--max-notes N] [--max-entries N] [--max-download-mib N]
                         [--max-minutes N] [--jobs N]
sempere sync webdav URL --vault V [--user U --password-env VAR] [--identity FILE]
                         (--metadata-only | --fetch [--note ID]... [--no-blobs] | --no-blobs) [--jobs N]
```

Mirrors the vault folder with a WebDAV collection (`docs/io.md`, "WebDAV
sync"); the server needs no logic. `URL` must be `https://`, or `http://` to
`localhost`, `127.0.0.1` or `[::1]`; anything else is refused (exit 2) before a
request is made, and so are credentials inside the URL. The password is read
from the environment variable named by `--password-env` (default
`SEMPERE_WEBDAV_PASSWORD`) and never from the command line. The vault folder
may be missing or empty: the first run pulls everything.

Revision files are copied to the side that lacks them and never overwritten.
`vault.json` is compared with the last sync (state
in `$XDG_STATE_HOME/sempere/sync/`); a change on one side is copied over. When
both sides changed it, with the vault unlocked, the later version by the home
device (the same epoch, every check passing, its list holding the other's:
`format.md` §1.3) is kept on both sides; any other change on both keeps both
copies (`vault.conflict-<device>-<time>.json` next to
the local file; `--device` names this machine, default the host name) and exits
3; a `vault.json` that differs only in its label (the vault renamed on both
sides) is the same vault and is taken from the server. The epoch records
(`epochs/`, first, before `vault.json`), join requests (`joins/`) and the passphrase copy (`keys/`) are
synced, and a `vault.json` of another epoch is judged by the device-change rules (`format.md` §15.15; above,
under "Sync"). `settings.age` changed on both sides is merged per key with the
vault unlocked and the result written to both sides (listed in `merged`; `docs/settings-sync.md` §8); locked, both
copies are kept and a conflict is reported, as for `vault.json`. The notebook records (`notebooks/`, `format.md` §14)
are write-once, so both sides end with the union. Deletions follow only compaction: a file removed on one side is removed on
the other only if the compaction rules (`docs/format.md` §5.3) allow it with
the revisions held locally, which needs the vault unlocked (this machine's
device key, `--identity`, or `--passphrase-env`/`$SEMPERE_PASSPHRASE` for a
passphrase-wrapped device key); otherwise
it is restored, or, with the vault locked, left alone and listed as skipped.
Each note's attachment blobs (`notes/<id>/att/`) are synced the same way:
streamed from and to disk, a blob file over `--max-blob-mib` (default 1088,
that is 1 GiB of content plus padding) neither uploaded nor downloaded but
reported as an error, never a partial blob under its name on either side.
An interrupted blob download continues from where it stopped on the next
run. A blob removed on one side (by `blobs gc`) is removed on the other only
if no revision of its note references it there and every revision of the
note could be read (`format.md` §8.1.6 rules 1–3); otherwise it is copied
back. Blob paths appear in the output and the JSON report like revisions
(`notes/<id>/att/<name>`).
Voice notes waiting in `inbox/` (`format.md` §11.4) are copied to the side that lacks them, each
checked before it is placed (unlocked, as `inbox import` reads it); one that one side deleted since
the last run is deleted on the other only when its adoption explains it (the note made from it is
here, with the vault unlocked), and otherwise copied back. Each device's `summaries/<device>.sealed`
(`format.md` §12.5) is copied to the side that lacks it, and of two copies the later version (sealed
inside the file) is kept on both sides; a copy that does not open is never replaced. This machine's
own file (its device id from `device.json`) is only ever uploaded, and left alone where the remote
holds a later copy of it (another install with the same device state).
With the vault unlocked, the server's `sempere-summaries.sealed` (`format.md`
§12; the note list the web viewer reads first) is rewritten after the sync to
describe what the server then holds (an entry per note whose revisions there
are exactly the local ones), when its entries changed. `--web-viewer` creates
it, and `sempere-index.json` (the viewer's one-request listing), on a server
that has none (and needs the vault unlocked, exit 2 otherwise). The file is never copied between the two sides, and a run
without the key leaves the server's copy as it is (listed as skipped). The
sync state remembers the server listing it was last written for, so an
unchanged server costs no request for it. A run that did not list every
note folder on the server (a folder's listing failed, or a run bound stopped
it while listing) updates neither file and lists them as skipped. A `--push-only` run publishes them the same way (to the server only); like
any push-only run it writes nothing in the vault, not even a refresh of a
local `sempere-index.json` or `sempere-summaries.sealed`.
A remote `vault.json` whose device list changed is copied over the local one
only when it is a later version of the local one by the home device and
checks (`format.md` §1.3, §2.1): the same vault, root and epoch, every tag and
signature verifying, and the local list's entries all still there. That needs
the key; without it only a copy that differs in its label alone is taken.
An older version, or a list that does not hold the local one, is never taken
(no merge). Anything else is reported as `rejected` (stderr line and `--json`
`rejected: [{path, message}]`), the local copy stays, and the exit code is 6.
A `vault.json` of another epoch is judged by the device-change rules
(`format.md` §15.15), with the vault unlocked: a later epoch whose chain
verifies is taken (`--json` `epoch.taken`; the vault is reopened, pinned and
this machine's own files caught up: `epoch.caughtUp`); one that cannot be
verified yet (its record has not arrived) leaves the local copy, uploads nothing
new and exits 3 (`epoch.waiting`, until a run finds the record); one that does
not list this machine exits 8 (`epoch.unlisted`, with `unsyncedChanges`), and
nothing is uploaded; when the local chain is the later one, the local copy
replaces the server's. `epochs/`, `joins/` and the passphrase copy in `keys/`
are synced too (`format.md` §15.15). Received files under an earlier key that no
device change sealed are kept aside on this machine (`setAside`, `sempere
set-aside`), never placed; files whose key's record has not arrived are
`pending` (fetched again once it does); an accepted copy that replaced an
unaccepted one (here or on the server) is listed in `replaced`. A complete
two-way run records this machine's `synced` time in its own summaries file
(at most hourly), which the home device's `devices remove` reads.
Every downloaded revision and blob is checked before it is placed
(`format.md` §9.1): with the vault unlocked (or, on a first pull, with
`--identity`) it must decrypt, verify its tag (a blob: its keyed name and
content hash) and name its note and file; locked, only its age structure is
checked. A file that fails is never placed in the vault: it is kept under
`<sync state>.quarantine/` (mode 0600, outside the vault; a later copy of the
same path with other bytes is kept beside the first as
`<name>.copy-<16 hex digits of its SHA-256>`, never over it, up to 16 copies
of a path), printed as
`quarantined: PATH: why` on stderr, listed in the JSON `quarantined`
(`{path, message}`), and the exit code is 1. Later runs do not fetch it
again while it, the local `vault.json` and the lock state are unchanged (it
is listed as skipped, `-v`); `--retry-quarantined` fetches and checks it
again. A run is bounded as a whole (`format.md` §9 table): `--max-notes`
(default 100000 note folders listed), `--max-entries` (1000000 remote entries
listed in all), `--max-download-mib` (65536) and `--max-minutes` (720).
Reaching one stops the run with an error naming the flag (exit 1, JSON
`stoppedEarly`); what was done is kept and the next run continues. `--max-minutes`
also cuts a request in flight (a download the server trickles), keeping a
blob's partial file for the next run. A note
folder whose listing fails is an error for that note only: it is left out of
the run (nothing is copied or deleted for it) and the rest syncs.
The `--json` report's `changed` says what the run wrote in the vault folder (`notes`: the ids of the
notes that got or lost a file; `manifest`, `journal`, `settings`, `inbox`, `notebooks`, `summaries`:
whether those changed), the same summary the app uses to read again only what arrived.
`--dry-run` makes no request that changes anything and writes nothing; it
lists `would upload`, `would download` and `would delete` lines. It cannot see
files it would first download, so it may under-report deletions.

**`--push-only`** makes the run a one-way mirror, for a server that is not
trusted to write back (for example a web server you control that serves the
web viewer, fed from a local vault copy on a schedule). It uploads what the server lacks (revisions, blobs,
`vault.json`, even files the server lost), replaces a
differing server copy of `vault.json` with the local
one (listed in `overwritten` and `uploaded`; a server `vault.json` of another
vault still aborts the run), and deletes on the server what local compaction
or `blobs gc` explains (as above, which needs the vault unlocked). A
differing `settings.age` is merged per key with the server's (when that copy
verifies) and the merge uploaded, with the vault unlocked; locked, the local
copy replaces it (`docs/settings-sync.md` §8). It never
downloads, and never writes, restores or deletes anything in the vault folder
(it needs an existing vault: no `vault.json` is exit 2). The reason: a
two-way sync rejects a `vault.json` whose device list changed without the
home device's signature (`format.md` §2.1), but still takes everything else a server holds; a
push-only mirror can be corrupted but never feeds anything back. Files only the server has:
if they were never synced and no compaction explains them (injected files,
junk names) they are `extraneous`: listed, and
with `--delete-extraneous` removed from the server. One that was synced before
but is missing locally without a compaction or collection to explain it (or
with the vault locked) is kept and listed as skipped, never deleted, since the
local copy may merely be evicted from iCloud. On the first sync to a server
(no sync state for it yet) every server file looks never synced, so
`--delete-extraneous` only lists them (as skipped) and removes them on a later
run; use `--dry-run` first when the local vault may not be fully downloaded.
`--delete-extraneous` needs `--push-only`, and `--push-only` an existing vault.

**`--keep-server-changes`** (with `--push-only`) keeps a server `vault.json`
that changed since this machine's last sync instead of
replacing it: someone else wrote it (the home device approving a device, say), and a
mirror that replaced it would undo that on the server. It is reported as a
conflict (`conflicts`, `remoteCopy` null: nothing is written locally) and the
exit code is 3; revisions and blobs still upload. Without a sync state for the
server, any differing copy is kept. A copy only this machine changed (the
server still holds what it last synced) is replaced as usual. This is how the
app pushes a WebDAV vault (`docs/io.md`, "WebDAV vaults in the app").

**Partial copies** (`format.md` §1.2, `docs/io.md` "Partial copies"): a vault
is pulled in steps instead of all at once.
- **`--metadata-only`** makes a partial copy in a new or empty folder (or
  continues one): `vault.json`, `settings.age` and the
  server's `sempere-summaries.sealed` (kept in `.sempere-partial/`), plus one
  empty folder per note marked as not downloaded yet. A few requests whatever
  the vault's size; nothing is uploaded or deleted. It refuses a complete vault
  (exit 2).
- **`--fetch`** fetches what a partial copy lacks: every note not downloaded
  yet, or only those named with `--note` (an id or an id prefix, repeatable),
  as the server holds them now, then their attachment blobs; with
  `--no-blobs`, revisions only (each missing blob keeps a stand-in). With a
  key (this machine's device key, `--identity`) each file is checked under the
  key, else for its age structure (as a first pull). It never uploads, never
  deletes and never changes `vault.json` or a note that is already complete,
  so it is safe while the vault is in use. When nothing is left, the copy is
  complete (`.sempere-partial/` goes) and the text output says so.
- **`--no-blobs`** alone does both steps: every note's revisions and no blob.
- An ordinary run (none of these flags) completes a partial copy too.

These flags do not go with `--push-only`, `--dry-run`, `--delete-extraneous`,
`--keep-server-changes`, `--web-viewer`, `--skip-unchanged` or `--no-deep-listing` (exit 2). While a
copy is partial: nothing is written to a note not downloaded yet (`notes
show`, edits and other per-note commands fail with "not completely downloaded";
`notes list` shows such notes with that problem); commands that must see every
file refuse it with "partial copy" (exit 1): `export --all` and bulk export,
`backup`, `search`, `compact --all`, `blobs` over every note, `recognize
--all`, `transcribe --all`, `vault index`, `vault summaries`, device key
changes. A `--push-only` run from a partial copy keeps on the server
everything the copy has not fetched (never deleted, never `extraneous`;
counted in `partial.keptOnServer` and in the summary line as "kept (not
fetched here yet)"), refuses `--delete-extraneous` (exit 1), and leaves the
server's `sempere-summaries.sealed` as it is while a note is not downloaded.
The JSON report of any run on a partial copy has `partial: {incompleteNotes,
pendingBlobs, keptOnServer, completed}`.

**`--skip-unchanged`** lists on the server only the note folders whose ETag
in the `notes/` listing changed since the last run left the note in step,
and whose local folder still holds the revisions that run recorded; the
others cost no request (a note's `att/` is still listed). It is used only
where the server is seen to change a folder's ETag when this machine writes
a revision into it, never with weak or missing ETags, and every note is
listed at least once a day (`docs/io.md`, "Unchanged notes"). The app's
pushes use it.

**Deep listing.** By default, with 8 to 5 000 note folders, a run lists all of
them and their `att/` with one `PROPFIND` (`Depth: infinity` on `notes/`)
instead of one request each, on a server seen to answer it in full: a run
first compares it with the one-by-one listings (and again once a day), and a
server that refuses it (Apache's default) or answers it as `Depth: 1` is
remembered and listed one by one (`docs/io.md`, "One listing for every note
folder"). `--no-deep-listing` always lists one by one.

```
sempere sync folder PATH --vault V [--identity FILE | --passphrase-env VAR] [--device NAME] [--wait SECONDS]
                         [--max-blob-mib N] [--web-viewer] [--dry-run] [--json] [--retry-quarantined]
                         [--push-only [--delete-extraneous] [--keep-server-changes]]
                         [--max-notes N] [--max-entries N] [--max-download-mib N] [--max-minutes N] [--jobs N]
```

The same two-way sync as `sync webdav`, with a folder as the other side (`docs/io.md`, "Folder
targets"): a folder in iCloud Drive or another provider's storage, on a USB drive, a network share,
anywhere. Every rule above applies unchanged: write-once files copied to the side that lacks them and
never overwritten, `vault.json` compared with the last sync (a later version by home taken, other
conflicts kept as copies with exit 3; a label-only difference taken; `epochs/`, `joins/` and `keys/` not
synced yet), `settings.age` merged per key, notebook records unioned,
deletions only by compaction and blob collection (with the vault unlocked), every file taken from the
folder checked before it is placed and quarantined otherwise (exit 1), a rejected `vault.json` exit 6,
the run bounds, `--jobs`, `--dry-run`, `--push-only` (with `--delete-extraneous` and
`--keep-server-changes`) and `--web-viewer` (a folder a web server serves to the web viewer). The JSON
report is the same object. `PATH` may be missing or empty (the first run copies the vault into it), and
so may the vault (the first run copies the folder's vault in; `--identity` checks it under the key).
The two must not overlap (exit 2), and `PATH` must be a folder (exit 2). The sync state is kept per
(folder, vault) pair like a server's.

In a provider's folder (iCloud Drive, a Mac's `~/Library/CloudStorage/…` providers), reads and writes
are coordinated with the provider. A file it has evicted (a `.<name>.icloud` stand-in or a dataless
file) is asked for and waited for, at most `--wait` seconds for the whole run (default 30, 0 to
86400); a folder it has listed before its files is left alone for two minutes, then taken as listed.
Such files exist: nothing is uploaded over them and no deletion is judged from them. What has not
arrived is printed as `arriving: PATH: why` on stderr, listed in the JSON `arriving` (`{path,
message}`), and the exit code is 1: run again. One still arriving 15 minutes after the first request
is an error instead. A `vault.json` in the folder that does not arrive stops the run before anything
is copied (exit 1). The provider's conflict versions of `vault.json` and `settings.age`
are merged, or kept as conflict copies, and removed, so no version picker appears.

The folder is not trusted: symbolic links in it are never followed, FIFOs and names that are not vault
files are not taken (listed as ignored with `-v`), reads are bounded. In a plain folder, conditional
writes (`vault.json`, `settings.age`) take an advisory lock on `.sempere-lock` in `PATH`, so the CLI and
the app on one machine take turns; on a file system without hard links (FAT) new files are checked and
renamed under it. Exit codes: 0 ok, 1 errors, quarantined files or files still arriving, 2 usage, 3
conflicts or a device change waiting to be verified, 6 a rejected `vault.json`, 8 this machine is not on the
newest device list.

```
sempere webdav check URL [--user U --password-env VAR] [--json]
```

Tests a WebDAV URL and lists the vaults there, as the app's "Test Connection"
and vault list do: a vault when `URL` holds a `vault.json`, otherwise the
vaults in the folders directly below it (at most 64 folders are looked into).
Same URL and password rules as `sync webdav`; the server's certificate must be
trusted by the system (the CLI has no certificate pinning: add a self-signed
CA to the system's trust store). Nothing is written. Text output: a line
saying what is there, then `<vault id>  <name>  <url>` per vault. `--json`:
`{url, reachable: true, outcome: "vault" | "vaults-below" | "no-vault", vaults:
[{path, name, folder, vaultId, format, url}], foldersChecked, foldersSkipped,
unreadable}` (`name` is the vault's `label`, format.md §2, when its `vault.json` has
one, else `folder`), or on failure `{url, reachable: false, problem, message}` with
`problem` one of `offline`, `unauthorized`, `certificate`, `not-found`,
`redirect`, `failed`. Names from the server are escaped and shortened. Exit 0
when at least one vault was found, 1 otherwise (no vault, or the server could
not be used), 2 usage.

**`--jobs N`** (1 to 16, default 6) lists the note folders and their `att/`,
downloads the files the vault lacks and uploads the files the server lacks,
N at a time (`docs/io.md`, "Concurrent transfers and progress"): on a slow
or distant server the round trips overlap. Each file is still checked,
quarantined or resumed as alone, a note's blobs travel before its revisions,
uploads still only create (never replace), and the run bounds hold across
the transfers in flight. Deletions and `vault.json` go one at a time. With `--fetch`, N is the fetch's own concurrency (default 4: note
folders and small revisions).

**Progress.** When stderr is a terminal (and neither `--json` nor `-q` is
given), one line on stderr is redrawn as the run goes: `listing notes 120 of
640`, then `downloading 12 of 800 files · 34.2 of 1024.0 MB`, then `syncing
notes …`; the last state stays on its line. `--metadata-only` shows its note
count, `--fetch` the files and MB it fetches. `SEMPERE_PROGRESS=always` shows it
when stderr is not a terminal (logs, tests), `never` turns it off. With
`--json` there is no live line: the report's `progress` object is the
summary (`stage` `done`, `notesListed`, `notesTotal`, `notesSynced`,
`filesDone`, `filesTotal`, `bytesDone`, `bytesTotal`, `uploaded`).

Output: one line per action, then
`N uploaded, N downloaded, N deleted, N conflicts, N errors` (`-q` hides the
lines, `-v` adds skipped and ignored entries). `--json` prints the report:
`dryRun`, `uploaded`, `downloaded`, `deleted` (`{side, path}`), `conflicts`
(`{path, remoteCopy, detail}`), `errors` and `skipped` (`{path, message}`) and
`ignored` (remote names that are not vault files), `merged` (`settings.age` when it was merged, below), `rejected`, `quarantined`
(`{path, message}`), `stoppedEarly` (only when a run bound or a cancellation stopped it), `progress` (above), `partial` (only on a partial copy, above), and with `--push-only` also `extraneous` and `overwritten` (these arrays are always present). One failing file does not stop the
run. Exit 0 ok, 1 errors or quarantined files, 2 usage (including a refused URL), 3 conflicts, 6 a
rejected `vault.json`.

### About

```
sempere about [--json] [-q | -v]
sempere --version
```

Prints what `--version` prints (the version line, `Copyright (C) 2026 Anthony
Wertz.`, the GPL notice "This program comes with ABSOLUTELY NO WARRANTY. This is
free software, and you are welcome to redistribute it under the terms of the
GNU GPL v3 or later." and links to the license and `SECURITY.md`), then the
source, where to report a vulnerability (GitHub private vulnerability reporting),
the security design and its limits (`docs/security.md`), and the third-party
software in this build with its license (`-v` adds a line on each, `-q` stops
after the notice). The first line of `--version` is always `sempere VERSION`
(release checks compare it with the tag). `--json` prints `program`, `version`,
`copyright`, `notice`, `license` (SPDX), `licenseURL`, `repositoryLicenseURL`,
`sourceURL`, `securityPolicyURL`, `reportVulnerabilityURL`, `securityDesignURL`
and `thirdParty` (`{name, license, url, note, products}`). The list and the
wording are `SempereAbout` (`Sources/Sempere/About.swift`), which the app's About
screen shows too. Exit 0.

## Worked examples

### Prepare for a lost device or key

```bash
sempere vault init ~/Sync/notes.sempere --recovery-out recovery.txt --name "laptop" --kind cli
sempere keys paper --identity recovery.txt --vault ~/Sync/notes.sempere --out kit.pdf
lp kit.pdf && rm kit.pdf recovery.txt   # print it, keep it with your passport; no device keeps it
sempere backup ~/Sync/notes.sempere --to /mnt/usb/notes-backup
sempere backup verify /mnt/usb/notes-backup   # this machine's device key opens it
```

Later, on a new computer with only the sheet and the backup disk:

```bash
# type the key lines into key.txt (or zbarimg --raw -q photo.png > key.txt)
age-keygen -y key.txt | tr -d '\n' | sha256sum | cut -c1-16   # the digest on the sheet
sempere restore /mnt/usb/notes-backup --to ~/notes.sempere --recovery-key key.txt
sempere export --all --format pdf --out ~/notes-pdf --vault ~/notes.sempere \
    --recovery-key key.txt --root "THE 16 GROUPS ON THE SHEET"
```

The recovery key reads; it never writes. Writing again from a new device
needs that device to join (below), which needs the home device; when home is
lost, the kit takes over instead:

```bash
sempere devices takeover --vault ~/notes.sempere --recovery-key key.txt \
    --root "THE 16 GROUPS ON THE SHEET"                 # shows the devices to keep
sempere devices takeover --vault ~/notes.sempere --recovery-key key.txt \
    --root "THE 16 GROUPS ON THE SHEET" --keep-listed --yes   # this machine is home now
```

If the device was stolen, remove it from the list (leave it out of the
takeover), then replace the kit (`recovery replace`): whoever holds the old kit
could take over too.

### Join a second device

With the vault folder shared between the two machines (a synced folder, or
copy `joins/` across with `vault merge-copy`):

```bash
# on the new machine:
sempere device init --vault ~/Sync/notes.sempere --name "linux box"
# On the home device, type these six words: …
# on the home device (the machine that created the vault):
sempere devices approve --vault ~/Sync/notes.sempere WORD WORD WORD WORD WORD WORD
# On the new device, type these six words: …
# back on the new machine, once the new vault.json has arrived:
sempere device confirm --vault ~/Sync/notes.sempere WORD WORD WORD WORD WORD WORD
sempere vault verify --vault ~/Sync/notes.sempere
```

Each device has its own key, kept in its own state folder; no key is copied
between devices.

### Export everything to PDF on Linux from a backup

```bash
tar xf notes-backup.tar            # from `sempere backup --archive`: contains notes.sempere/
export SEMPERE_VAULT=$PWD/notes.sempere
sempere vault verify --recovery-key ~/key.txt     # exit 0 = every file decrypts and its tag matches
sempere export --all --format pdf --out ~/notes-pdf --recovery-key ~/key.txt
sempere export --all --merge --format pdf --out ~/all-notes.pdf --recovery-key ~/key.txt
```

Add `--deleted` to include notes you deleted. With only the passphrase copy
in the backup, pass it as the key (`--recovery-key
notes.sempere/keys/recovery-*.key.age`) with `SEMPERE_PASSPHRASE` set (or
answer the prompt); it carries the root, so no `--root` is needed.

### Recover one note with nothing but age

You have the recovery key in `recovery.txt`, the vault's `vault.json` and one
file, `17600...-ab12cd34-3.snapshot.age`, and no `sempere` binary. Files are
encrypted to the vault identity, which the recovery entry's wrap holds
(`docs/format.md` §15.13, the kit's script):

```bash
jq -r '.keys[] | select(.role == "recovery") | .wrap' vault.json | age -d -i recovery.txt > vault-keys.txt
age -d -i vault-keys.txt 17600...-ab12cd34-3.snapshot.age | tail -c +38 | gunzip | jq .
```

A post-quantum key (`AGE-SECRET-KEY-PQ-1...`) needs `age` 1.3 or later (the
official release binaries; distribution packages may be older).

The first 37 bytes of the decrypted body are the `SMPR` header and HMAC tag
(`docs/format.md` §4); `tail -c +38` skips them. Newest snapshot first: it
carries the whole note (title, pages, strokes). With the binary, the same
thing is `sempere recover FILE.age --recovery-key recovery.txt` (or
`--identity vault-keys.txt`), which also checks the tag when the vault folder
is next to the file.
