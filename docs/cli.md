# The `sempere` command line

The Linux and macOS face of Sempere: keys, vault management, note editing,
verification, export and recovery. Everything the app does to vault data can
be done here and scripted with `--json` (the CLI-first rule in `CLAUDE.md`);
only the drawing itself needs the app. It builds with `swift build -c release --product sempere`
and CI publishes a static Linux binary. The executable only parses arguments,
talks to the terminal and sets exit codes; everything else lives in
`Sources/Sempere` and `Sources/SempereRender`.

## Global conventions

| Option | Meaning |
| --- | --- |
| `--vault PATH` | The vault directory (`*.sempere`). Env `SEMPERE_VAULT`. |
| `--identity FILE` | An age identity file (`age-keygen` style). Repeatable. Env `SEMPERE_IDENTITY` (one path). |
| `--passphrase-env VAR` | Name of the environment variable holding the passphrase of the vault's stored key file. |
| `--json` | Machine-readable output where it makes sense (everything except `recover`, `keys generate` without `--out`, and `keys export` without `--out`). |
| `-q`, `-v` | Quieter (data only, or only problems) / more detail. |
| `--version`, `--help` | On every command. `--version` prints `sempere VERSION`, then the copyright and the GPL notice (no warranty; free to redistribute under the GPL v3 or later) and links to the licence and `SECURITY.md`; `sempere about` adds the rest. |

`--vault`, `--identity` and `--passphrase-env` apply to the commands that open
an existing vault. Times are printed in your local time zone with an offset;
`--json` uses UTC (`Z`).

**Getting a key.** Commands that read notes need an identity. In order:
`--identity` files (or `$SEMPERE_IDENTITY`); otherwise the passphrase-wrapped
keys stored in the vault's `keys/` directory, unlocked with the passphrase from
`--passphrase-env VAR`, else `$SEMPERE_PASSPHRASE`, else a no-echo prompt on
the terminal. Every stored key the passphrase opens is used, as in the app (a
migration may need both the classic and the post-quantum key); a key file it
does not open is skipped, and any other problem with one is an error. A passphrase never goes on the command line. Secret keys are
printed only by `keys generate`, `keys export` and `keys paper` (into its PDF).

**Exit codes**

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Generic failure (I/O, bad input, corrupt file, refusing to overwrite). |
| 2 | Usage error (unknown option, missing vault, bad recipient string). |
| 3 | `vault verify` or `backup verify` found problems, a restored vault is not healthy, a recipient change is incomplete, or `backup status --max-age` found no complete backup in that many days. |
| 4 | Cannot decrypt: wrong key or passphrase, or no key available (no identity, no passphrase and no terminal to ask, or a `--passphrase-env` variable that is not set). |
| 5 | Legacy vault: it still lists a classic X25519 key, so it may only be migrated. The message names the command: `migrate first: sempere vault recipients replace OLD NEW`. |
| 6 | Untrusted device list: `vault.json`'s recipients do not check (`format.md` §2.1: changed without the vault's key, its tag removed, or the vault secret replaced in a way this machine cannot confirm). Every command that would encrypt to the list refuses (nothing is written), `vault verify` reports it, and `sync webdav` exits 6 when it rejected a remote `vault.json`. The message names the unexpected keys and `sempere vault recipients repair`. Reading notes still works. |
| 7 | Read-only vault: it holds content of a newer format version (format.md §7), so this version may read it but not change it. The message says why (`format`, `features`, or notes a newer version wrote). |

**Legacy vaults** (format.md §3.3.2) are migrate-only. On a vault that lists a
classic X25519 recipient, alone or next to post-quantum ones, only these run:
`vault info`, `vault recipients add` (post-quantum key) / `remove` /
`replace`, `vault rewrap-resume`, and `recover` (the stock-`age` equivalent,
which reads one file and needs no migration). Every other command that opens
a vault (`notes …`, `notebooks …`, `tags …`, `pages …`, `export`, `search`, `compact`, `snapshot`, `import`,
`vault verify`, `keys export`, `keys paper --vault`, `sync webdav`,
`backup --prune`, `backup verify`, `restore`) exits 5 before asking for a key
or passphrase. `backup V --to DIR` (without `--prune`) and `backup V --archive`
are allowed too: they copy the encrypted files without decrypting anything,
and a copy before migrating is a good idea. `restore` is refused because it
would hand back a legacy vault; migrate the backup folder (itself a vault)
first. `keys generate` and `keys show` do not touch a vault.

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
`vault recipients …`, `vault rewrap-resume`, `inbox enable`/`import`,
`recognize`, `transcribe`) exits 7 without changing a file. `vault index`
exits 7 too unless it writes elsewhere (`--out FILE` or `-`), and no command
refreshes the vault's `sempere-index.json` any more. Newer
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
| `SEMPERE_IDENTITY` | Default identity file. |
| `SEMPERE_PASSPHRASE` | Passphrase for the vault's stored key file, for scripts and tests. |
| `SEMPERE_TITLE_FORMAT` | Default for `notes new --title-format` ([Editing notes](#editing-notes)). |
| `SEMPERE_PDFTOPPM` | Poppler's `pdftoppm` for PDF page backgrounds in SVG/PNG exports (default: `pdftoppm` on `PATH`; [PDF page backgrounds](#pdf-page-backgrounds)). |
| `SEMPERE_PDFTOTEXT` | Poppler's `pdftotext` for the text of imported PDF pages (default: `pdftotext` on `PATH`; [`import pdf`](#import-pdf)). |
| `SEMPERE_WEBDAV_PASSWORD` | The WebDAV password, unless `--password-env` names another variable ([Sync](#sync)). |
| `SEMPERE_BUNDLED_FONTS` | The directory of the fonts shipped with the CLI ([Text in exports](#text-in-exports)). |
| `SEMPERE_FONT_DIR` | An extra directory of font packs, searched first ([Text in exports](#text-in-exports)). |
| `XDG_STATE_HOME` | Where this machine's state lives under `sempere/` (`device.json`, recipient trust, sync and capture state; default `~/.local/state`). |
| `XDG_CACHE_HOME` | Where the summary cache lives (default `~/.cache`; [Notes](#notes)). |
| `XDG_DATA_HOME` | Font packs under `sempere/fonts` (default `~/.local/share`; [Text in exports](#text-in-exports)). |

## Commands

### Keys

```
sempere keys generate [--out FILE]
sempere keys show FILE
sempere keys export --vault V [--recipient age1...] [--out FILE]
sempere keys paper --out KIT.pdf [--identity FILE] [--vault V] [--passphrase [--work-factor 15...18]]
                    [--paper letter|a4]
```

- `generate` writes an `age-keygen`-style identity (mode 0600, refuses to
  overwrite) and prints the public key. Without `--out` the identity goes to
  stdout and the public key to stderr. Keys are always post-quantum
  MLKEM768-X25519 (`AGE-SECRET-KEY-PQ-1...`, recipient `age1pq1...`, as
  `age-keygen -pq` makes); vaults take no other kind. Decrypting their files
  with the stock CLI needs `age` 1.3 or later; on Apple platforms the key
  type needs macOS 26.
- `show` prints the public key (`age1...` or `age1pq1...`) of an identity file.
- `export` decrypts the vault's passphrase-wrapped key file
  (`keys/<key-name>.key.age`, format.md §3.2) to a plain identity file, to move a key to
  another device. `--recipient` is needed only if the vault stores several.
- `paper` writes a two-page printable PDF recovery kit (mode 0600, refuses to
  overwrite). Page 1: the key as a QR code (byte mode, error correction Q,
  version 6 for an `AGE-SECRET-KEY-1…` line), the key as text in numbered
  lines grouped by 5 with a 4-digit checksum per line, the public key, and with
  `--vault` the vault name, id and creation date; a boxed warning that **the
  sheet is the key**. Page 2: recovery step by step with stock tools
  (`age -d -i key.txt FILE.age | tail -c +38 | gunzip | jq .`, a loop that dumps
  every note's newest snapshot) and with `sempere restore` / `export`.
  The line checksum is the first 4 hex digits of SHA-256 of the line as typed:
  `printf '%s' 'LINE' | sha256sum | cut -c1-4`. The key also carries its own
  Bech32 checksum (its last 6 characters, a BCH code over the whole key): any
  typo of up to 4 characters makes `age` reject it, but only the line checksums
  say which line is wrong; `age-keygen -y key.txt` must print the public key on
  the sheet. With `--vault` the key must be one of the vault's recipients
  (else exit 4). Without `--identity` the key comes from the vault's stored key
  file (passphrase as for any command).
  `--passphrase` prints a passphrase-wrapped copy of the key instead (armored
  age, scrypt, `--work-factor` default 18; QR error correction M). It wraps only
  the secret key line, so a post-quantum key's 1959-character public key never
  ends up in the QR code (it would not fit). The passphrase is the one of the
  vault's stored key file for this key (checked by opening it), otherwise one
  you choose (`--passphrase-env VAR` / `$SEMPERE_PASSPHRASE` / the terminal,
  confirmed). Either way the command decrypts what it prints before writing the PDF.
  That sheet is safe to store less carefully, but useless without the
  passphrase. `--json` emits `path`, `variant` (`plain` or `passphrase`),
  `publicKey`, `vaultId`, `qrVersion`, `qrErrorCorrection` and `lines`.
  Delete the PDF once it is printed.

  **Post-quantum keys** (`AGE-SECRET-KEY-PQ-1…`, 77 characters, from
  `age-keygen -pq`): the same sheet. Kits are printed only for post-quantum
  keys: a classic `AGE-SECRET-KEY-1…` key is refused ("create a new key", exit
  2), and so is a legacy vault given with `--vault` (exit 5). The first line is the `AGE-SECRET-KEY-PQ-1`
  prefix, then 58 characters in lines of 20, and the QR code is version 7 at
  level Q (45×45 modules, against version 6 for an X25519 key). The public key is 1959 characters and cannot be
  read or typed from paper, so the sheet prints its first characters, its length and
  the first 16 hex digits of its SHA-256 instead; page 2 gives
  `age-keygen -y key.txt | tr -d '\n' | sha256sum | cut -c1-16` to check the rebuilt
  key against it. Page 2 also says that `age` 1.3 or newer is needed (Ubuntu's apt
  package is older). `backup`, `restore` and the archive copy `keys/*.key.age`
  whatever the file name, so the hash-named key files of post-quantum recipients
  (`age1pq-<64 hex>.key.age`) are included.

**The app's key actions and the CLI.** Settings ▸ Device Keys, the Vault
Keys window and the recipients alert in the app do the same with the same
code (`IdentityFile.render`, `RecoveryKit`, `Vault.addRecipient`,
`replaceRecipient`, `repairRecipients`, `confirmRecipients`):

| App | CLI |
| --- | --- |
| Save Key… (this device's key, after Face ID) to Files or the share sheet | the identity file you unlock with, or `sempere keys export --vault V --out key.txt` from the vault's passphrase-wrapped copy |
| Save Key… → Print Recovery Kit / Save as PDF | `sempere keys paper --identity key.txt --vault V --out kit.pdf` |
| New Key… (label) | `sempere keys generate --out new.txt`, then `sempere vault recipients add --vault V "$(sempere keys show new.txt)" --label LABEL` |
| New Key… → Save to Files / Share / Recovery Kit | `new.txt` itself; `sempere keys paper --identity new.txt --vault V --out kit.pdf` |
| Vault Keys ▸ Replace Key… (paste a public key, or generate one) | `sempere vault recipients replace --vault V OLD NEW [--label LABEL]` (`sempere keys generate --out new.txt` first to generate) |
| Recipients alert → Remove | `sempere vault recipients repair --vault V` |
| Recipients alert → Choose Devices to Keep… | `sempere vault recipients repair --vault V --keep KEY ...` |
| Recipients alert → Trust This List | `sempere vault recipients confirm --vault V` |

The app adds two rules to the CLI's `repair --keep`, since a wrong pick
cannot be undone from the device that made it: the key the app unlocked with
is always kept (and a repair is refused when that key is in neither the list
nor this device's record), and keeping a key this device never confirmed asks
for the owner check first (Face ID, Touch ID or the passcode), as adding a key does. Replace Key… refuses the key
the app unlocked with (add a key for this device, unlock with it, then remove
the old one): replacing it would lock the app out, and an interrupted replace
of it can only be finished with both keys. Remove refuses that key too, and
so does the CLI's `recipients remove` unless another key the command unlocked
with stays listed (`--force` overrides).

The app's key file is the CLI's (`age-keygen` style: `# created`, `# public
key`, the `AGE-SECRET-KEY-PQ-1…` line), named `Sempere key - <label>.txt`.
The app never writes it except where the user chooses: "Save to Files" writes
it only into the picked folder, and the share sheet gets a copy in the app's
temporary folder (file protection complete, mode 0600) that is deleted when
the share sheet closes, when the sheet goes away, and at the next launch.

### Vault

```
sempere vault init PATH --recipient age1... [--recipient ...] [--label TEXT ...]
                         [--store-key FILE [--passphrase-env VAR] [--work-factor 15...18]]
sempere vault info
sempere vault recipients add age1pq1... [--label TEXT] [--rewrap header|reencrypt] [--store-key FILE [--store-passphrase-env VAR] [--work-factor 15...18]]
sempere vault recipients remove age1... [--force] [--rewrap header|reencrypt]
sempere vault recipients replace age1old... age1pq1new... [--label TEXT] [--rewrap header|reencrypt] [--store-key FILE ...]
sempere vault recipients repair [--keep age1pq1... ...] [--dry-run] [--rewrap header|reencrypt]
sempere vault recipients confirm
sempere vault link [status|upgrade]
sempere vault markers [status|tag|repair]
sempere vault rewrap-resume
sempere vault verify
sempere vault index [--out PATH|-]
sempere vault summaries [--out PATH|-] [--plaintext] [--no-cache]
```

- `init` creates the vault. `PATH` must end in `.sempere`. Give no `--label`
  or one per `--recipient`. Labels (here and in `recipients add`/`replace`)
  are stored as the app stores them: one line, trimmed, at most 80
  characters; an empty one is shown as "Device". `--store-key` also writes that identity,
  passphrase-wrapped, into `keys/` (the passphrase is confirmed when typed,
  and an empty one is refused with exit 2, as in the app).
- `info` prints vault id, creation time, recipients with labels, number of
  notes, stored key files, whether a recipient change is pending and whether
  its journal is readable. It works without a key (the journal check then says
  "not checked"); with an identity or a scripted passphrase it checks it.
- `recipients add` / `remove` rewrap every file to the new recipient set
  (`remove` also rotates the vault secret) and print a report. If any file
  cannot be rewrapped the exit code is 3 and the message says to run
  `rewrap-resume`. Removing a key does not revoke what it already decrypted.
  `remove` refuses (exit 2) the key the command unlocked with, unless another
  key it unlocked with stays listed: unlock with another key, or pass `--force`.
- Attachment blobs (`notes/<id>/att/`, `format.md` §8.1.5) are rewrapped
  too. By default an `add` rewrites each blob's age header only (same file
  key, payload copied), and a `remove` or `replace` (or an `add` that changes
  the key types, such as a post-quantum key added to a legacy vault)
  re-encrypts each blob under a new file key; a removal also renames every
  blob under the new vault secret. `--rewrap header|reencrypt` overrides the
  method for this change. `header` on a removal is faster but leaves every
  old copy of a blob (backups, file-version history) able to open the current
  file with the removed key. The method is recorded in the journal, so
  `rewrap-resume` (from any device) finishes with the same one. `--json`
  reports it as `blobs`.
- Voice notes waiting in `inbox/` (`format.md` §11) are re-encrypted to the
  new set and re-tagged under the new capture key, so they are still adopted
  after a removal. One that verifies under neither the current nor the
  outgoing capture key (forged, or sealed with a profile revoked earlier) is
  left as it is, reported (`--json`: `inboxSkipped`) and does not make the
  change incomplete. Run `inbox enable` again on machines that capture.
- Recipients must be post-quantum (`age1pq1...`): `init`, `recipients add`
  and the new key of `replace` refuse a classic `age1...` key with "create a
  new key" (exit 2), before asking for any passphrase. Legacy vaults that
  still list X25519 keys open as before and are migrated with `replace` or
  `add` + `remove` (format.md §3.3.2). A classic identity given to a
  post-quantum vault fails with the same advice (exit 4).
- `recipients add` / `replace --store-key FILE` also store the new
  recipient's identity (FILE, which must be that key) passphrase-wrapped in
  `keys/`, with the passphrase from `--store-passphrase-env VAR`, else
  `$SEMPERE_PASSPHRASE`, else the terminal (confirmed; not empty). Use it when the
  vault is unlocked by passphrase: only key files of current recipients are
  offered for passphrase unlocking, so after a `replace` the old key file
  (left in `keys/`) no longer is.
- `recipients replace` swaps one recipient for another with a single rewrap
  and a secret rotation: the post-quantum migration (format.md §3.3.2). An
  interrupted replace is finished by `rewrap-resume` with **both** keys
  (`--identity OLD --identity NEW`), so keep the old key until `info` shows
  no pending rewrap.
- Recipient arguments may be the key itself or a file holding it: a
  recipients file (first non-comment line) or an identity file, of which only
  the `# public key:` line is read. Post-quantum recipients are 1959
  characters, so files are handier.
- `info` abbreviates post-quantum keys, shows each recipient's type
  (`x25519` / `mlkem768x25519`, `type` in `--json`) and a `Post-quantum:`
  line: `yes` only when no X25519 recipient is left.
- **Authenticated device list** (`format.md` §2.1). `vault.json` carries
  `recipientsTag`, an HMAC of the vault id and the recipient keys under a key
  derived from the vault secret, so nobody without the key can add a device
  (a sync server, a shared folder). `init` and every `recipients` command
  write it in the same write as the list (a secret rotation also writes
  `secretLink`, Ed25519 and ML-DSA-65 signatures by the old secret's keys,
  which prove it was made with the old secret). With a key,
  every command checks the list against this machine's trust record
  (`$XDG_STATE_HOME/sempere/trust/<vault id>.json`, mode 0600, kept by
  commands that write; it holds only the two public keys that check a link). A list that does not check is
  refused for writing with exit 6 (see Exit codes); reading still works. An
  older vault without a tag is tagged by the first command that writes to it,
  which reports it once on stderr ("vault.json's device list is now
  authenticated … check them with `sempere vault info`"); read-only commands
  never write `vault.json`.
- `info` has a `Device list:` line and `recipientsAuth` in `--json`:
  `status` (`verified`, `untagged`, `tampered`, or `not-checked` without a
  key), `tagged`, and for `verified` a `verification` (`unchanged`,
  `firstUse`, `rotated`: a secret rotation confirmed by its `secretLink`),
  for `tampered` a `reason` (`tagMismatch`, `tagRemoved`,
  `secretUnconfirmed`, `recordUnreadable`: this machine's trust record exists
  but does not read, so nothing can be compared until `recipients confirm`),
  `unexpected` (keys not in the last verified list),
  `missing` and `restore` (what `repair` would write).
- `recipients repair` undoes a tampered list: it writes the last verified
  list (this machine's record, or the list the tag still verifies once the
  inserted keys are deleted), keeping the current labels, as a recipient
  removal: the vault secret rotates and every file is rewrapped, so nothing
  stays encrypted to an unexpected key. `--keep KEY` (repeatable) names the
  keys instead, needed when this machine never wrote to the vault. `--dry-run`
  prints (`--json`: `reason`, `unexpected`, `keep`) and writes nothing. A
  replaced vault secret cannot be repaired (the files are tagged under a
  secret this machine no longer has): restore `vault.json` from a backup or
  another device (exit 1 says so).
- `recipients confirm` trusts the current list on this machine after you
  have checked every key: for a secret change this machine missed (it was
  offline for two or more key changes), an
  untagged copy older than the tag (a restored backup), which it tags again,
  or a trust record of this machine that no longer reads (it is written again).
  Never for a tag that does not verify, and never for changed version markers
  (`markersMismatch`, `markersRemoved`, `markersRolledBack`: exit 1, use
  `markers repair`); markers that do not check behind a list problem are
  written back as `markers repair` would. Confirming a list an attacker wrote
  lets them read what this machine writes.
- `link` (or `link status`) shows the form of `vault.json`'s `secretLink`
  (`none`, `signed`, `legacy` HMAC, `malformed`), whether the vault is marked
  `signed-secret-link`, and this machine's trust record (`none`, `signed`:
  public keys only, `legacy`: the HMAC record of earlier versions); `--json`
  gives `link`, `featureListed`, `record`, `needsUpgrade` and `recipientsAuth`.
  Works without a key. `link upgrade` (needs the key) does the one-time move
  to signed links (`format.md` §2.1 "Upgrading to signed links"): it replaces
  a legacy record by a signed one, retires a legacy link (re-signs it while
  an interrupted rewrap still holds the old secret) and marks the vault, after
  which older Sempere versions stop writing to it. `--json` adds `upgrade`
  (`link`: `none`, `reSigned`, `retired`; `featureAdded`; `recordUpgraded`).
  A second run changes nothing. A list that does not check is refused
  (exit 6). Any write also upgrades this machine's record; a legacy record
  never confirms a changed secret, so a machine that missed a key change
  before upgrading runs `recipients confirm`.
- `markers` (or `markers status`) shows whether `vault.json`'s `format` and
  `features` are authenticated (`format.md` §2.1 "Version markers", security
  review 2026-10, N3) and check: `--json` gives `format`, `features`,
  `tagged`, `status` (`verified`, `untagged`, `tampered`, `not-checked`
  without a key), `reason` and `recorded` (the markers this machine last
  verified). A vault whose markers were changed without the key
  (`markersMismatch`), lost their tag (`markersRemoved`) or went back to an
  older `vault.json` (`markersRolledBack`, which only a machine that wrote to
  it can tell) is refused for every write (exit 6) and reported by `info`,
  `verify` and the device-list lines; reading works. `markers tag` (needs the
  key) authenticates the markers of an older vault once, as its first write
  would anyway (`--json`: `tagged`, `status`). `markers repair` (needs the key)
  writes the larger of the markers on disk and those this machine last verified
  (the higher format, every feature of either), tagged; it refuses a result
  naming a format or feature this version does not implement.
- `rewrap-resume` finishes an interrupted change; it refuses (exit 6) a list
  that does not check, so a planted journal cannot re-encrypt the vault to a
  planted key.
- `verify` decrypts, tag-checks and decodes every file and prints
  `status  path` per file plus counts, and a `RECIPIENTS` line (the device
  list, as in `info`). Exit 0 only if the vault is healthy, 6 when the device
  list does not check, else 3. `-q` lists only problem files. `--json` emits
  `healthy`, `manifestProblems`, `rewrapPending`, `journalProblem`, `counts`,
  `files` and `recipientsAuth` (as in `info`).
  Attachment blobs are decrypted and hashed in full: `ok`, `unreferenced`
  (healthy: no revision of its note uses it; `blobs gc` removes it later),
  `invalid` (bad framing, padding, hash or name), `staleRecipients`, and a
  `missing` line for each reference with no blob.
- `index` writes `sempere-index.json` at the vault root (or `--out PATH`;
  `--out -` prints it): every note id and its revision file names, the
  listing the web viewer reads on a static server that cannot list folders
  (`docs/web-viewer.md` "Hosting"). It needs no key and holds only names that
  storage already shows. Once it exists it is kept current automatically:
  every command that opens the vault rewrites it when the listing changed (a
  failure to do so is a warning), and `sync webdav` rewrites the server's
  copy when the server has one. A WebDAV share needs no index. Legacy vaults are refused (exit 5), as the
  viewer cannot read them. `--json` emits `path`, `notes` and `revisions`.
- `summaries` writes `sempere-summaries.sealed` at the vault root (or `--out
  PATH`; `--out -` prints it): the published note summaries of `format.md`
  §12, which the web viewer lists and searches a vault from without decrypting
  every revision (`docs/web-viewer.md` "Opening fast"). Per note: title, tags,
  notebook, favorite and deleted flags, created and modified dates, page count
  and each page's searchable text, with the revision file names it was made
  from; notes with an unreadable revision get no entry. Sealed with AES-256-GCM
  under a key derived from the vault secret, so it needs the key (exit 3
  without it) and only the vault's keys open it. Entries of an existing file
  whose notes did not change are reused (others go through the summary cache
  unless `--no-cache`), so a rerun reads only changed notes. Once it exists it
  is kept current: every command that unlocks the vault rewrites it when a
  note changed (a failure is a warning); commands without the key leave it
  alone, so it may lag until the next one. `--plaintext` writes the JSON
  content instead, in the clear (for checks and the web goldens); it needs
  `--out`, so it never lands at the vault's sealed path by default, and a
  file it writes is readable by its owner only (created 0600 next to the
  target, then renamed over it). Legacy
  vaults are refused (exit 5). `--json` emits `path`, `notes`, `entries`,
  `read` (notes summarised again) and `bytes`.

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
  the blob it is unreferenced. The first blob adds `features: ["attachments"]`
  to `vault.json`.
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
  revision, a pending rewrap). Read only: the dates come from this device's
  record without updating it, so a blob never seen before shows today. Exit 3
  when a note could not be checked. The app keeps its own record, so the
  dates can differ between the app and the CLI on one Mac.
- `gc` deletes those that have been unreferenced for `--retention` days
  (default 30), per `format.md` §8.1.6: per note, only when every revision of
  the note was read and verified, no recipient change is pending, no revision
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
  revision, pending rewrap) or a blob could not be verified.
  Collection never happens as a side effect of `compact`, `sync` or opening.
- `repair` fixes blobs a recipient change by an older build left behind
  (still named under an old vault secret, encrypted to old recipients, or
  under the wrong kind): each is verified, re-encrypted to the current
  recipients and renamed. Only authentic blobs are touched (the name verifies
  under the current secret, or a verified revision of the note references the
  content); anything else is listed and left alone (exit 3).

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

The commands the app's add flows have, scriptable (`docs/attachments.md` §14
task F). Each stores the file's bytes as an encrypted blob of the note
(`blobs add` does the same without a placement), then writes **one delta**
through the same `NoteOps` the app uses, with this machine's device id and
clock (as `snapshot`). NOTE is an id, an id prefix or an exact title; a
deleted note is refused. Pages are numbered from 1 as `pages list` prints
them (`--page` defaults to 1); coordinates are points from the page's top-left.
Standard output is the new item's (or recording's) id, one per line, so
`ID=$(sempere attach image …)` works; the confirmation goes to standard error
(`-q` silences it). `--json` prints `{note, file, dryRun, blob, items,
recording, pagesAdded}`: `file` is the delta written (`null` with `--dry-run`),
`blob` the reference stored (`sha256`, `size`, `type`), `items` the added items
as `notes show --json` prints them (`{page, pageId, item}`), `recording` the
recording added or changed. `--dry-run` checks the file and the placement and
says what would be added; it writes neither the blob nor a delta. A blob
stored before a failing delta is unreferenced; `blobs gc` collects it. Nothing
is stored when the file or the placement is refused (exit 1; bad options are
exit 2).

- `image` takes a JPEG or PNG. The stored bytes have location and camera
  metadata removed (every APPn segment but JFIF, ICC and Adobe, and comments,
  in a JPEG; ancillary chunks but the colour ones in a PNG) unless
  `--keep-metadata`; a JPEG's EXIF orientation is first copied to the item's
  `orientation`, so it still shows upright (`format.md` §8.2.5). HEIC, WebP,
  GIF, TIFF and CMYK or arithmetic-coded JPEGs are refused: convert them first.
  The file must decode, stay under 100 megapixels and 64 MiB. Without a frame
  the image is shown at one pixel per point, shrunk to fit inside a 36 pt
  margin, centred across the page and a margin from its top; `--at` and
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
  equation's colour on a transparent page; the frame is then the PDF's page
  size (`--width` scales it, keeping the aspect), and `--engine` records what
  made it. The equation is searchable (`sempere search`), and Markdown and HTML
  exports keep its source as `$$…$$` (display) or `$…$` (inline). `items math`
  changes it later.
- `pdf` stores the PDF once and places pages of it (`--pages`, default all;
  the list keeps its order). By default each selected page becomes a **new note
  page** with the PDF page as a background that fills it (layer 0; fitted and
  centred when its size differs from the note's page size), inserted after note
  page `--after` (0: before the first; default the end), all in one delta.
  The note's page size is not changed, and a pageless note takes no inserted pages.
  With `--page` (and `--frame`, or `--at` and `--width`, and `--crop` on the
  effective page) **one** PDF page is instead placed as a figure on an existing
  page, in the content layer; `--pages` must then select exactly one. Encrypted
  PDFs, files that are not PDFs, PDFs with more than 2 000 pages or a page
  without a usable size are refused. Annotations and form fields are not drawn
  (`format.md` §8.2.6).
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
  keeps its length and every sample offset, so it plays as before; the file on
  disk is not changed. Other codecs (MPEG-4 Part 2, VP9, AV1), WebM, AVI and
  fragmented MP4 are refused: convert first (`ffmpeg -i IN -c:v libx264 -c:a
  aac OUT.mp4`, or `-c copy` to defragment). The poster frame is what exports
  and readers that do not play video draw: `--poster IMAGE` (JPEG or PNG,
  stored upright without metadata; an image with an EXIF rotation is refused),
  else on macOS a frame taken from the clip with AVFoundation
  (`--poster-time`, default 0.5 s, upright, at most 1920 px), else (Linux, or
  `--no-poster`) none: renderers draw a crossed box with a play mark, and
  `items poster` can add one later. Without a frame the clip is fitted inside
  the margins at most 480 pt wide, centred across the page, a margin from the
  top; `--at`, `--width`, `--frame`, `--rotation`, `--layer` and `--rec` as
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
  card (narrower on a narrow page), centred across the page a margin from its
  top, above the page's other items; standard output is then the item's id,
  then the recording's, and `--json` lists the item in `items`. `recordings
  place` places one later. `--rec ID` on `image` and `text` links an item to a
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
  card centred across page 1 (or `--page`) a margin from its top, or at
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
  `rewrap-journal.json` exists on either side, because a recipient change
  rewrites revision files without changing their size (replacing one key by
  another); then every file is compared by hash. A file whose content changed (`vault.json`,
  `rewrap-journal.json`, `keys/`, every revision after a recipient change) is
  replaced and its previous copy kept under `DIR/versions/<UTC time>/<path>`;
  a journal the vault no longer has moves there too. Nothing else is ever
  deleted: revisions the vault no longer has (compaction) stay, unless
  `--prune`, which deletes only those that a snapshot covers that the vault
  and the backup hold byte for byte identically (checked on disk, not from
  the index; the rules of `docs/format.md` §5.3, as `sync` applies them). A file lost from the vault without a covering snapshot is
  never pruned, and neither is an attachment blob
  (`notes/<id>/att/`, `format.md` §8.1.6: collection is per device, so a
  backup keeps every blob it has seen). `--prune` needs the key (exit 4
  without). An interrupted run
  (crash, full disk, Ctrl-C) leaves only complete files; running it again
  finishes the job and removes leftover temporary files.
  `DIR` is itself a vault (`sempere --vault DIR` reads it) plus
  `DIR/backup.json` (vault id, and SHA-256 and size of every file the backup
  wrote) and `DIR/versions/`. Output: `copied`, `replaced` and `pruned` lines
  and a count line (`-v` adds versioned and kept files). `--json` emits
  `vaultId`, `destination`, `copied`, `replaced`, `versioned`, `unchanged`,
  `pruned`, `kept` and `errors` (`{path, message}`). One failing file does not
  stop the run. Exit 0 ok, 1 some files failed, 2 usage, 4 `--prune` without a key.
- `backup V --archive FILE.tar` writes one uncompressed POSIX tar of the
  encrypted files under `<name>.sempere/` (refuses an existing file). It is
  written to a temporary file, read back and checked member by member, then
  renamed. `tar xf FILE.tar` gives back a vault folder. `--json`: `archive`,
  `vaultId`, `files`, `bytes`, `sha256`.
- `backup verify DIR` without a key checks every file in `backup.json` (present,
  same size and SHA-256: a flipped byte or a missing file is found) and that
  `vault.json` is well formed. With `--identity` (or a scripted passphrase for
  the key file the backup holds) it also decrypts, tag-checks and decodes every
  revision like `vault verify`. Files on disk that `backup.json` does not list
  (`unindexed`, from a run cut short) are not problems. Exit 0 healthy, 3
  problems, 4 the key does not open the vault. `--json` emits `healthy`,
  `decrypted`, `backupProblems`, `vaultProblem`, `manifestProblems`,
  `rewrapPending`, `counts` and `files` (`{path, status, detail}`; index
  statuses `ok`, `missing`, `modified`, `unindexed`, plus the vault check's
  problem statuses).
- `backup status DIR` reads `DIR/backup.json` only (no key, no other file)
  and prints the vault id, the first (`created`) and last (`updated`) run, the
  last run that finished without a file error (`completed`; absent, or
  `never` in text, until one does, and in folders written before this field
  existed), and the `notes`, `files` and `bytes` it records, previous copies
  under `versions/` apart (`versionFiles`, `versionBytes`; `totalBytes` is
  both). `updated` moves with every run, failed or cut short ones too, so
  only `completed` says a backup worked. It checks nothing: `backup verify`
  does. Exit 0, or 1 when `DIR` is not a backup or its `backup.json` cannot
  be read. `--json` emits those fields.
- `backup status DIR --max-age DAYS` (1 to 3650) is the app's "Remind Me"
  for scripts: the backup is overdue when no run completed in the last DAYS
  days, counted from `completed`, else from `created` (a folder whose runs
  all failed, or one written before `completed` existed, is overdue DAYS
  days after its first run: one complete run clears it). A `completed` more
  than a day in the future (a clock that ran ahead, an edited file) counts as
  overdue rather than postponing the check. Overdue exits 3 and prints
  `OVERDUE` on the `due` line; `--json` adds `maxAgeDays`, `due` and
  `overdue`. The rule is the app's (`BackupSchedule`), with "last complete
  run" for the app's "last backup".
- `restore DIR --to NEWPATH` copies `vault.json`, `keys/` and `notes/` (not
  `versions/` or `backup.json`) into a new or empty folder ending in
  `.sempere`, checking every file against `backup.json`; a file that does not
  match is not restored and is reported. `DIR` may also be any vault folder
  (say, an extracted tar). `vault.json` is written last, so an interrupted
  restore is never mistaken for a vault; the same command finishes it. The
  result is then verified: every revision with `--identity`, structure only
  without. Exit 0 ok, 1 files not restored, 2 usage (`NEWPATH` without
  `.sempere`), 3 the restored vault is not healthy, 4 wrong key. `NEWPATH`
  may not be, hold or lie inside the vault named by `--vault` or
  `$SEMPERE_VAULT` (exit 1: restore never touches a vault in use).
  `--dry-run` writes nothing: it refuses `NEWPATH` exactly as a restore would,
  then shows what `DIR` holds, read without a key: `notes`, `revisions`,
  `attachments`, `keyFiles`, `bytes`, `newestRevision` (the newest revision
  file's clock, so a device whose clock ran ahead can put it in the future),
  `isBackup`, `backupUpdated` and `legacy` (a classic-key vault, which
  restore refuses). `--json` emits those fields with `source` and `vaultId`.

#### Scheduling backups

A backup run is cheap when nothing changed (it lists and compares sizes), so
run it often. Use absolute paths; no key is needed (do not put one in a
scheduled job unless you use `--prune`).

cron (Linux, macOS), every hour, plus a weekly check and a daily reminder
when no run has completed for a week (cron mails what a job prints, so only
an overdue backup produces mail):

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
(`--archive`): do those with the CLI. On purpose (gap audit GA-18):

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
sempere notes list [--tag T] [--notebook N] [--deleted] [--no-cache]
sempere notes show ID|TITLE
sempere notes new [TITLE] [--title-format PATTERN] [--notebook PATH] [--tag T]... [--paper KIND] [PAPER OPTIONS] [--page-size letter|a4] [--no-cache]
sempere notes rename ID|TITLE NEW-TITLE
sempere notes tag ID|TITLE [--add T]... [--remove T]... [--no-cache]
sempere notes move ID|TITLE (NOTEBOOK | --none)
sempere notes paper ID|TITLE [KIND] [--page N] [PAPER OPTIONS]
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
hidden unless `--deleted`. `--notebook` takes a notebook path and lists the
notes in it or below it, comparing whole segments (`A/B` holds `A/B/C` but not
`A/Bc`), as the app's sidebar does; `--tag` ignores case. Notes are read in parallel without their stroke
geometry, and the summaries are kept in an encrypted per-device cache
(`$XDG_CACHE_HOME/sempere/`, default `~/.cache/sempere/`; `format.md` §10), so
a later `list` reads only notes whose revision files changed. A damaged cache
is ignored and rewritten; `--no-cache` neither reads nor writes it. `show` prints the metadata, how many pages have recognised text (`Text:`; `recognizedPages`
in `--json`), the note's placed items (text boxes, images, PDF pages, unknown
kinds; by page in drawing order: page, kind, layer, frame, the text or the
blob's type, size and hash prefix, id) and recordings (start, duration, title,
blob, whether it has a transcript, id), and the revision history
(kind, wall time, file name; `-v` adds the app string). `--json` adds `items`
(each `{page, pageId, item}`, `item` in its `format.md` §8.2 form) and
`recordings` (§8.3.1 form), both without the snapshot-only `origin` and
`clocks`; `list --json` gains the counts `items` and `recordings`. A note is named by its
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
to the sheet that holds its vertical centre. No ink is deleted and none moves
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
its title, notebook, tags or a page's recognised text (case, accents and width
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
| `--background`, `--line-color`, `--margin-color` | `#RRGGBB` or `#RRGGBBAA` | colours |

```
sempere notes new "Week 3" --notebook School/Physics --tag physics --paper grid --spacing 18
sempere notes paper "Week 3" cornell --page 2
sempere notes tag "Week 3" --add exam --remove draft
sempere notes language "Week 3" es-ES
sempere notes markers "Week 3" behind
sempere notes favorite "Week 3"
sempere notes list --favorites --json
```

`notes list --json` (and the `note` of every edit's `--json`) includes `lang`
(when set), `markersBehindText` and `favorite`.

#### Strokes left over by concurrent edits

When two devices slice (pixel eraser), move or recolour the same stroke
without seeing each other's edit, every reader keeps the later edit and hides
the other one's strokes (`format.md` §5.6.1). `notes dedupe` lists, per note:

- **superseded** strokes: hidden that way, but still added by revisions.
  Readers that predate the rule (older app or CLI builds) still draw them;
  removing them makes those agree.
- **duplicates**: live strokes that descend from the same stroke as other
  live strokes through another edit, which the merge cannot resolve: a stroke
  brought back by undo or a restore while another device sliced it, or
  vaults compacted by builds that predate the rule (their snapshots hold both
  sets of pieces and nothing to tell them apart). The descendants of the
  latest edit are kept.

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
sempere notebooks rename OLD NEW [--dry-run]
sempere notebooks move NOTEBOOK (PARENT | --top-level) [--dry-run]
sempere tags list [--no-cache]
```

`notebooks list` prints the notebook tree (parents included, even when they
hold no note directly) with `NOTES`, the notes directly in a notebook, and
`TOTAL`, those in it or below it; deleted notes count only with `--deleted`.
`--json` gives `path`, `depth`, `notes` and `total` per notebook.

`notebooks rename` renames or moves a notebook with everything below it: each
note in `OLD` or below it, deleted ones too, gets the `OLD` prefix of its
notebook replaced by `NEW`, one delta per note (as the app's sidebar rename).
Paths compare by whole segments, so renaming `A/B` leaves `A/Bc` alone. An
empty `NEW` (`""`) takes the notes directly in `OLD` out of any notebook and
lifts its sub-notebooks to the top level. Every note is read first, without
the cache; if any cannot be read the command writes nothing and exits 1 (its
notebook is unknown, so it would be left behind). `--dry-run` lists the notes
that would move. `--json` gives `from`, `to`, `dryRun` and `notes`
(`note`, `title`, `from`, `to`, `file`).

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
```

`list` prints each page's number, id, stroke count, paper (its own, or the
note's marked `*`) and whether it has recognised text. `--json` gives `note`,
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
paper and recognised text right after it under new ids.

A deleted note is refused (exit 1), as is a page number out of range.
`--json` as for the editing commands.

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
break shows as a line break. The source is the box's text (one run), so older
readers show it as plain text; the line breaks stored are those of the
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
colour, alignment, direction and language, `--no-markdown` the other way; the
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
the new picture's proportions inside the old frame, centred on it, with the
old rotation and stacking and no crop (`NoteOps.replaceImage`; anything but an
image is refused before anything is written; prints the new item's id;
`--json`: `note`, `changed`, `file`, `item`, `replaced`, `blob`), `math` writes an
equation's whole value (`NoteOps.setMath`, `format.md` §8.2.8): the options
given replace the source, style, size or colour, checked as `attach math`
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

`sempere import` has one subcommand for each importer the build contains (`notability` today, plus the built-in `pdf`).
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
(Notability's Google Drive backup; pass **every part** of a backup Drive split
into several zips in one run); see `docs/import-notability.md` for the
mapping. All inputs are read before anything is written, so copies of one
note anywhere in them are resolved together: the newest `.note` with ink is imported,
copies whose strokes it already has are skipped (`duplicate:`, `older
version:`, or `superseded:` for an `.ntb` copy, each naming the source that
was imported), and a copy holding strokes the chosen one lacks is imported as
a separate note titled `<title> (version modified <date>)` and gets a
`separate version …` line. An `.ntb` without a `.note` is imported from the
bundle.

One row is printed per input file (status, title, notebook, strokes written,
pages with recognised text, source) plus a summary line; `-v` lists what was
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
TIFF are converted to PNG; WebP and other formats are reported and left out. `--no-attachments` imports ink, recognised
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

Newer `.ntb` bundles keep their PDF and images as top-level `<sha256>.pdf` /
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
ink but no recognised text (Notability never indexed it) right after the
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
rotation); later pages of another size are fitted and centred; paper is blank.
The whole note is one delta. The title is `--title` (one file only) or the file
name without `.pdf`; `--notebook` and `--tag` as for `notes new`; `--pages`
imports a subset. Encrypted PDFs (remove the password first, e.g. `qpdf
--decrypt`), non-PDFs and PDFs with more than 2 000 pages are refused. Prints
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
analysis, so multi-column text comes out in drawing order). `builtin` and
`poppler` force one (`poppler` without `pdftotext` is an error); `none`
stores no text. A page with no extractable text (a scan) stores nothing.
`attach pdf --json` adds `pagesWithText` and `textEngine`.

### Search

```
sempere search TERM [--transcripts]
```

(To find notes rather than every occurrence, ranked as in the app, use
`notes search`.)

Case-insensitive, accent-insensitive substring search over every page's
recognised handwriting text (the Notability import, on-device recognition),
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
`pageId`, `engine` and `words` (the recognised words containing the term with
their `[x, y, w, h]` boxes) for handwriting; `page`, `pageId`, `itemId` and `box`
(the text box's or equation's frame) for text and math; `page`, `pageId`, `itemId`, `box` (the PDF
page item's frame), `pdfPage` (1-based page of the PDF) and `engine` (what
extracted the text) for pdf; `recordingId`, `recordingTitle`, `start`,
`end` (seconds), `engine` for a transcript (no `page`). No match prints `No
matches.` (an empty list with `--json`) and exits 0. Notes are read in parallel
and without stroke geometry, as for `notes list`.

`--show-boxes` reports where each match is, as the app's "3 of 12" stepper
does: every recognised word containing a word of the term, numbered across the
note (pages in order, words in reading order). Human output adds one line per
match (`NOTE p.PAGE  N of M  WORD  [x, y, w, h]`); with `--json` every hit gains
`locations`, a list of `{n, of, text, box}` for the matches on that hit's page
(`n` counts from 1 over the whole note, `of` is the note's total). Words inside
a text box are located too (a `text` hit gets its own `locations`, each with the
box's `itemId`): the box's text is laid out with the fonts `export` draws with
and each match is the glyph extent of the matched letters, `0.8 × size` above the
baseline to `0.25 × size` below it, turned with the item (a right-to-left line
highlights the whole line). Within a page, recognised words come first, then text
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

A page whose ink is gone has its recognised text cleared (except
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
Math" (docs/research/handwriting-to-latex.md), with the same code. The ink is picked with stroke ids
(or unique prefixes of 4+ characters), a rectangle or a loop of page points (a stroke is taken when
at least half of its control points are inside: `InkLasso`), or every stroke of the page
(`--all-ink`; markers' highlights are left out). It is drawn as the model wants it (`MathInkImage`:
black lines of one width, scaled into the model's input) and read on this machine by a converted
model, `--model DIR` (a `sempere-math-model/1` folder: `manifest.json`, two Core ML packages and a
tokenizer; every file is checked against its SHA-256 before anything runs; `tools/math-model/convert.py`
makes one). The readings come best first, with a score (mean log-probability per token).

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
§5.4 `lang`, once notes carry it), else this machine's; it is matched to a
supported one (the same tag, else the same language with this machine's
region, else the first of that language). Each recording's audio is decrypted
into a private temporary file (mode 0600) for the recogniser and deleted
afterwards.

By default only recordings without a transcript are read; recordings named on
the command line (id, id prefix of 4+ characters, or exact title) are read
whatever they have, and `--force` replaces every transcript. `--dry-run` lists
what would be read and works on every platform. `--check` prints which engines
can transcribe here, for which language, and needs no vault (it is the
availability matrix of task E5; `--json` gives `{supported, engines: [{engine,
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
same path as the app's widgets, Control Center control and Siri. `enable`
writes this machine's **capture profile** (the vault's public recipients and
the device capture key of the key it was unlocked with, which can only add
captures and never reads anything) to
`$XDG_STATE_HOME/sempere/capture/<vault id>.json`, mode 0600. Captures are
**attributed** to that key's device (`format.md` §11.1): another machine's
profile cannot seal one that passes as this one's. Run it again after a key is
removed from the vault (that rotates the capture key), and once to replace a
profile made before attribution (its captures are adopted as unattributed). It refuses (exit
6) a device list that does not check (`format.md` §2.1): captures are sealed to
the profile's list and nothing else, so a profile is only ever made from a
checked one. `capture` reads
only `vault.json` and the profile, no identity or passphrase. It seals the
audio file into `inbox/<id>.capture.age` (encrypted to the recipients, tagged
with the capture key) and prints the capture id. `--transcript` seals a
`sempere-transcript/1` file with it, and `transcript` seals one later; either
way its recording id is replaced by the capture's, and it is bound to the
capture's audio (`format.md` §11.2): `transcript` needs that audio file
(`--audio`, the bytes that were captured), and a transcript bound to other
audio is never adopted, nor is one sealed by another device than its
capture's. Both refuse (exit 7) a vault of a newer format. `list` shows the inbox:
ids and file kinds without a key, with one the titles, whether each verifies
and who captured it (`from iPad (device 0b0b0b0b)`, `from Device (…)` for a
key with no label, `from a device no longer in this vault (…)`, or
`(unattributed)`).
A capture sealed by a device that is no longer in the vault never verifies,
also while the rewrap of its removal is unfinished (security review 2026-10,
C3): it is reported and kept.
`import` adopts each capture as a note in the capture's notebook ("Inbox"),
titled from its date: the audio and transcript as blobs, then one delta as this
machine (the recording records who captured it, `captured`, `format.md`
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
fingerprint of the key the capture is attributed to, `capturedBy` its label);
`import` gives `{dryRun, captures: [{capture, note, title, created,
transcript, file, removed, error, captured, capturedBy}]}`.

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
are refused like every write: exit 5 for a legacy vault, 6 for an untrusted device
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

File names are the sanitised title plus the first 8 characters of the note id
(`Physics-Week-3-0d1c6a1e.pdf`). `--out` is a directory (created if needed),
except that a single note's pdf/json goes to the file when `--out` ends in
`.pdf`/`.json`. `--all` skips deleted notes unless `--deleted`; a deleted note
named explicitly is exported with a warning. One note that fails to
reconstruct does not stop the others; the exit code is then 1. Every file
written is printed. With `--json`, each entry has `note`, `files` and, when
some items were drawn as placeholders, `placeholders` (their number), and
`recordings` (the number embedded) with `--recordings attach`.

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
verification fails the note (exit 1, nothing of it left behind). A note without media writes nothing and warns "no recordings, videos,
images or PDFs to export" (exit 0). With `--json`, `files` lists the files written, `media.json`
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
  default, `flat`, writes every note directly in `--out`, as before.
- `--zip`: `--out` is a zip archive (stored entries, zip64 when needed) holding
  the same tree; notes are staged in the temporary directory one at a time.
- Names: two notes whose names would clash in a folder (same title and id
  prefix, equal ignoring case or Unicode normalisation, or equal to a
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
  `--recordings list`, keep the old in-memory path; `--attachments` (both) is
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
  per page (default 30; then SIGTERM, then SIGKILL), as much CPU time, 3 GiB
  of address space where the OS enforces it, an output file no larger than the
  requested pixels need, no core dumps. A PDF that makes Poppler hang, crash
  or write garbage costs at most one timeout and becomes a placeholder.
- Anything that cannot be drawn (no renderer, a missing or invalid
  attachment, an unreadable or encrypted PDF, a failed render, an item kind
  this export does not draw yet) is a placeholder: the item's frame outlined in
  grey with both diagonals (`docs/format.md` §8.5.2). The export still
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
  (and anything else decoded) as lossless 8-bit RGB or grey with a soft mask
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
- **Placeholders:** an item that cannot be drawn is a crossed-out grey box
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
white page back into coverage of the equation's colour, so the paper shows
around it. An equation without a rendering (written by `attach math` alone),
or whose rendering cannot be drawn (missing, damaged, no Poppler for SVG or
PNG), is drawn as its LaTeX source in a monospace font at its size and colour,
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
- A text box that cannot be laid out (no shaper: library callers that pass
  no `RenderOptions.shaper`, such as the app's share export until it has
  one) is a placeholder, reported like any other.

#### Markdown and HTML exports

> **These formats write your notes as PLAINTEXT.** The vault is end-to-end
> encrypted; `--format markdown|html` decrypts it into ordinary files (text,
> PDF, PNG, SVG) that anyone with access to the folder can read, and that
> cloud-sync or backup tools will copy. Choose the output folder accordingly
> (an encrypted volume, not a synced public folder). Nothing is encrypted again.

`--out` is always a directory. Notebooks mirror as folders: the notebook
`School/Math` (`format.md` §5.4) is `School/Math/`; each segment is sanitised
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
  has an image or recognised text. Front matter keys: `title`, `id`, `created`,
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
- Recognised text (`format.md` §5.5), when a page has it, under that page as
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
pages from the SVG writer; light and dark CSS; title, notebook, dates and
tags; a link back to the index) and `index.html`: notes grouped by notebook
and a search box filtering as you type over title, notebook, tags and
recognised text, ignoring case, accents and width as the app's search does (a few lines of inline script; the page works without it,
unfiltered). Recognised words are also laid over the ink as an invisible
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

### Recover

```
sempere recover FILE.age [--note-id UUID] [--identity FILE ...] [--vault PATH] [--no-verify]
```

Given an attachment blob (`notes/<id>/att/<name>.<kind>.age`) it prints the
blob's content, byte for byte what
`age -d -i KEY FILE | tail -c +46 | head -c LEN` prints (`format.md` §8.1.7).
Framing, zero padding and the content hash are always checked; the file name
too when a vault is known (a name that does not verify: exit 1, nothing
printed); otherwise `UNVERIFIED NAME: ...` goes to stderr. Content streams as
it is decrypted: if the command fails midway, discard the output.

Decrypts one revision file and prints its JSON to stdout, byte for byte what
`age -d -i KEY FILE | tail -c +38 | gunzip` prints. It needs only an identity
file and the one `.age` file. If a vault is known (`--vault`, else `vault.json`
found in a parent directory of the file, else `$SEMPERE_VAULT`) and the identity
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

`--thin-all` is the same rule with no age window ("thin everything except
checkpoints", `docs/format.md` §5.8.4 with a cutoff of zero): every autosave
goes, however recent, except the newest save of each editing session; every
checkpoint (saved versions and imports, §5.8.1) and the note's newest revision
stay. It prints its own rule line. `--retention`, `--thin-older-than` and
`--thin-all` are different modes; give one.

Thinning and compaction decide from each revision's metadata (names, wall
times, checkpoint and session fields, snapshot coverage) which notes have
anything to delete, and read only those in full; that metadata comes from the
summary cache (`docs/format.md` §10, filled by listings; `--no-cache` reads
every note instead). Notes are read, planned and carried out in parallel.

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
                         [--skip-unchanged] [--max-notes N] [--max-entries N] [--max-download-mib N] [--max-minutes N]
```

Mirrors the vault folder with a WebDAV collection (`docs/io.md`, "WebDAV
sync"); the server needs no logic. `URL` must be `https://`, or `http://` to
`localhost`, `127.0.0.1` or `[::1]`; anything else is refused (exit 2) before a
request is made, and so are credentials inside the URL. The password is read
from the environment variable named by `--password-env` (default
`SEMPERE_WEBDAV_PASSWORD`) and never from the command line. The vault folder
may be missing or empty: the first run pulls everything.

Revision files are copied to the side that lacks them and never overwritten.
`vault.json` and `rewrap-journal.json` are compared with the last sync (state
in `$XDG_STATE_HOME/sempere/sync/`); a change on one side is copied over, a
change on both keeps both copies (`vault.conflict-<device>-<time>.json` next to
the local file; `--device` names this machine, default the host name) and exits
3. Deletions follow only compaction: a file removed on one side is removed on
the other only if the compaction rules (`docs/format.md` §5.3) allow it with
the revisions held locally, which needs the vault unlocked (`--identity`, or
`--passphrase-env`/`$SEMPERE_PASSPHRASE` for the stored key file); otherwise
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
With the vault unlocked, the server's `sempere-summaries.sealed` (`format.md`
§12; the note list the web viewer reads first) is rewritten after the sync to
describe what the server then holds (an entry per note whose revisions there
are exactly the local ones), when its entries changed. `--web-viewer` creates
it, and `sempere-index.json` (the viewer's one-request listing), on a server
that has none (and needs the vault unlocked, exit 2 otherwise). The file is never copied between the two sides, and a run
without the key leaves the server's copy as it is (listed as skipped). The
sync state remembers the server listing it was last written for, so an
unchanged server costs no request for it. A `--push-only` run publishes them the same way (to the server only); like
any push-only run it writes nothing in the vault, not even a refresh of a
local `sempere-index.json` or `sempere-summaries.sealed`.
A remote `vault.json` whose device list changed is copied over the local one
only when it checks (`format.md` §2.1): its tag verifies under the secret it
carries, and that secret is the local one or a rotation confirmed by its
signed `secretLink` (checked with this machine's trust record's public keys,
else the local vault's secret). That needs the key; without it only a list with the same keys is
taken. Anything else is reported as `rejected` (stderr line and `--json`
`rejected: [{path, message}]`), the local copy stays, and the exit code is 6.
Every downloaded revision and blob is checked before it is placed
(`format.md` §9.1): with the vault unlocked (or, on a first pull, with
`--identity`) it must decrypt, verify its tag (a blob: its keyed name and
content hash) and name its note and file; locked, only its age structure is
checked. A file that fails is never placed in the vault: it is kept under
`<sync state>.quarantine/` (mode 0600, outside the vault), printed as
`quarantined: PATH: why` on stderr, listed in the JSON `quarantined`
(`{path, message}`), and the exit code is 1. Later runs do not fetch it
again while it, the local `vault.json` and the lock state are unchanged (it
is listed as skipped, `-v`); `--retry-quarantined` fetches and checks it
again. A run is bounded as a whole (`format.md` §9 table): `--max-notes`
(default 100000 note folders listed), `--max-entries` (1000000 remote entries
listed in all), `--max-download-mib` (65536) and `--max-minutes` (720).
Reaching one stops the run with an error naming the flag (exit 1, JSON
`stoppedEarly`); what was done is kept and the next run continues.
`--dry-run` makes no request that changes anything and writes nothing; it
lists `would upload`, `would download` and `would delete` lines. It cannot see
files it would first download, so it may under-report deletions.

**`--push-only`** makes the run a one-way mirror, for a server that is not
trusted to write back (the web viewer's NAS share, fed from the Mac's iCloud
vault every few minutes). It uploads what the server lacks (revisions, blobs,
`vault.json`, `rewrap-journal.json`, even files the server lost), replaces a
differing server copy of `vault.json` / `rewrap-journal.json` with the local
one (listed in `overwritten` and `uploaded`; a server `vault.json` of another
vault still aborts the run), and deletes on the server what local compaction
or `blobs gc` explains (as above, which needs the vault unlocked). It never
downloads, and never writes, restores or deletes anything in the vault folder
(it needs an existing vault: no `vault.json` is exit 2). The reason: a
two-way sync rejects a `vault.json` whose recipients changed without a valid
tag (`format.md` §2.1), but still takes everything else a server holds; a
push-only mirror can be corrupted but never feeds anything back. Files only the server has:
if they were never synced and no compaction explains them (injected files,
junk names, a stray `rewrap-journal.json`) they are `extraneous`: listed, and
with `--delete-extraneous` removed from the server. One that was synced before
but is missing locally without a compaction or collection to explain it (or
with the vault locked) is kept and listed as skipped, never deleted, since the
local copy may merely be evicted from iCloud. On the first sync to a server
(no sync state for it yet) every server file looks never synced, so
`--delete-extraneous` only lists them (as skipped) and removes them on a later
run; use `--dry-run` first when the local vault may not be fully downloaded.
`--delete-extraneous` needs `--push-only`, and `--push-only` an existing vault.

**`--keep-server-changes`** (with `--push-only`) keeps a server `vault.json` or
`rewrap-journal.json` that changed since this machine's last sync instead of
replacing it: someone else wrote it (another device's key change, say), and a
mirror that replaced it would undo that on the server. It is reported as a
conflict (`conflicts`, `remoteCopy` null: nothing is written locally) and the
exit code is 3; revisions and blobs still upload. Without a sync state for the
server, any differing copy is kept. A copy only this machine changed (the
server still holds what it last synced) is replaced as usual. This is how the
app pushes a WebDAV vault (`docs/io.md`, "WebDAV vaults in the app").

**`--skip-unchanged`** lists on the server only the note folders whose ETag
in the `notes/` listing changed since the last run left the note in step,
and whose local folder still holds the revisions that run recorded; the
others cost no request (a note's `att/` is still listed). It is used only
where the server is seen to change a folder's ETag when this machine writes
a revision into it, never with weak or missing ETags, and every note is
listed at least once a day (`docs/io.md`, "Unchanged notes"). The app's
pushes use it.

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
[{path, name, vaultId, format, url}], foldersChecked, foldersSkipped,
unreadable}`, or on failure `{url, reachable: false, problem, message}` with
`problem` one of `offline`, `unauthorized`, `certificate`, `not-found`,
`redirect`, `failed`. Names from the server are escaped and shortened. Exit 0
when at least one vault was found, 1 otherwise (no vault, or the server could
not be used), 2 usage.

Output: one line per action, then
`N uploaded, N downloaded, N deleted, N conflicts, N errors` (`-q` hides the
lines, `-v` adds skipped and ignored entries). `--json` prints the report:
`dryRun`, `uploaded`, `downloaded`, `deleted` (`{side, path}`), `conflicts`
(`{path, remoteCopy, detail}`), `errors` and `skipped` (`{path, message}`) and
`ignored` (remote names that are not vault files), `rejected`, `quarantined`
(`{path, message}`), `stoppedEarly` (only when a run bound stopped it), and with `--push-only` also `extraneous` and `overwritten` (these arrays are always present). One failing file does not stop the
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
GNU GPL v3 or later." and links to the licence and `SECURITY.md`), then the
source, where to report a vulnerability (GitHub private vulnerability reporting),
the security design and its limits (`docs/security.md`), and the third-party
software in this build with its licence (`-v` adds a line on each, `-q` stops
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
sempere keys paper --identity ~/.config/sempere/key.txt --vault ~/Sync/notes.sempere --out kit.pdf
lp kit.pdf && rm kit.pdf          # print it, keep it with your passport
sempere backup ~/Sync/notes.sempere --to /mnt/usb/notes-backup
sempere backup verify /mnt/usb/notes-backup --identity ~/.config/sempere/key.txt
```

Later, on a new computer with only the sheet and the backup disk:

```bash
# type the key lines into key.txt (or zbarimg --raw -q photo.png > key.txt)
age-keygen -y key.txt                                  # prints the public key on the sheet
sempere restore /mnt/usb/notes-backup --to ~/notes.sempere --identity key.txt
sempere export --all --format pdf --out ~/notes-pdf --vault ~/notes.sempere --identity key.txt
```

### Move a key to a second device

The vault stores your identity passphrase-wrapped (`vault init --store-key`).
On the second device, with the vault folder synced over:

```bash
sempere keys export --vault ~/Sync/notes.sempere --out ~/.config/sempere/key.txt
# Vault passphrase: ********
export SEMPERE_IDENTITY=~/.config/sempere/key.txt
sempere vault verify --vault ~/Sync/notes.sempere
```

Prefer a key per device? Generate one there and add it from a device that
already has access:

```bash
sempere keys generate --out ~/.config/sempere/key.txt        # prints age1new...
# on the first device:
sempere vault recipients add age1new... --label "linux box" \
    --vault ~/Sync/notes.sempere --identity ~/.config/sempere/key.txt
```

### Export everything to PDF on Linux from a backup

```bash
tar xf notes-backup.tar            # from `sempere backup --archive`: contains notes.sempere/
export SEMPERE_VAULT=$PWD/notes.sempere
export SEMPERE_IDENTITY=~/key.txt
sempere vault verify              # exit 0 = every file decrypts and its tag matches
sempere export --all --format pdf --out ~/notes-pdf
sempere export --all --merge --format pdf --out ~/all-notes.pdf
```

Add `--deleted` to include notes you deleted. With only the passphrase-wrapped
key in the backup, drop `SEMPERE_IDENTITY` and run with
`SEMPERE_PASSPHRASE` set (or answer the prompt).

### Recover one note with nothing but age

You have `key.txt` and one file, `17600...-ab12cd34-3.snapshot.age`, and no
`sempere` binary:

```bash
age -d -i key.txt 17600...-ab12cd34-3.snapshot.age | tail -c +38 | gunzip | jq .
```

A post-quantum key (`AGE-SECRET-KEY-PQ-1...`) needs `age` 1.3 or later (the
official release binaries; distribution packages may be older).

The first 37 bytes of the decrypted body are the `SMPR` header and HMAC tag
(`docs/format.md` §4); `tail -c +38` skips them. Newest snapshot first: it
carries the whole note (title, pages, strokes). With the binary, the same
thing is `sempere recover FILE.age --identity key.txt`, which also checks the
tag when the vault folder is next to the file.
