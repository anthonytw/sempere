# Sempere test fixture vault

**TEST-ONLY. `sample.key` and `sample-recovery.key` are throwaway keys committed
on purpose so that tests (and the CLI tests) can open the fixture vaults. Never
encrypt anything real to them.**

| File | What it is |
| --- | --- |
| `sample.key` | The fixture device's key file (`DeviceKeys` format: its age identity, `age -i` readable, and its P-256 and ML-DSA-65 signing seeds as `#` lines), test-only. The device is the fixture vaults' home, id `e6f8004e` |
| `sample-recovery.key` | The fixtures' recovery key (`format.md` §3.1), a plain post-quantum age identity, test-only |
| `sample.sempere/` | A small vault in the format of `docs/format.md` (key hierarchy, one epoch) |
| `sample.sempere/keys/recovery-<fingerprint>.key.age` | The passphrase copy of the recovery key (`format.md` §15.11): passphrase `sempere-test`, scrypt work factor 15 (writers use 20; test-only) |
| `sample.sempere/epochs/1-<16 hex>.epoch.age` | Epoch 1's record (`format.md` §15.6) |
| `notability/synthetic.note` | The importer tests' synthetic Notability note (`SyntheticNote.package()` in `Tests/SempereImportTests`): no personal data. The app's Notability import tests read it |
| `notability/portrait.heic`, `notability/portrait-heic.note` | A landscape HEIC turned upright to portrait by its `irot` (red top, blue bottom, green top right; written by ImageIO with orientation 6), and a Notability note holding it (`PortraitHEICTests`, `SEMPERE_UPDATE_FIXTURES=1`). The app's `PortraitHEICAppTests` check its exports (device check c35) |
| `items.sempere/`, `newer.sempere/` | Vaults with items and of a later format version (below) |
| `audio/`, `video/` | Synthetic tones and test-pattern clips; each folder's README has the ffmpeg commands |
| `text/` | Text-box line breaks and Markdown layout expected by the renderers and the web viewer |
| `settings/` | Shared-settings files (`format.md` §13) of this version and of later ones |
| `epoch-vectors.json`, `epoch-chain-vectors.json`, `epoch-precedence-vectors.json` | Key-hierarchy vectors shared with the web viewer (`format.md` §15) |
| `concurrent-replacement-vectors.json` | Vectors shared with the web viewer (`format.md` §5.6.1) |

`*.key` is git-ignored repository-wide; `sample.key` was added with `git add -f`.

## Contents

Vault id `5a3b1e00-1000-4000-8000-000000000001`, created
2026-10-04T16:20:00Z. `vault.json` lists one device, `sample.key`'s (id
`e6f8004e`, the home), and the recovery key `sample-recovery.key`. The
revisions were written under the device ids `a1b2c3d4` (A) and `99ee00ff` (B)
(revision names carry the writer's device id; ids decide nothing).

| Note | Revisions | Reconstructs to |
| --- | --- | --- |
| `11111111-1111-4111-8111-111111111111` | A1, B1, B2 deltas; A2 snapshot; A3 delta after it | title "Fixture lecture", tags `["fixture"]`, ruled paper, 2 pages with 2 strokes each |
| `22222222-2222-4222-8222-222222222222` | A1 delta, B1 `deleteNote` | title "Fixture deleted", `deleted: true`, 1 page with 1 stroke |

`items.sempere` (same device and recovery keys as the sample, and its own passphrase copy; vault id `5a3b1e00-1000-4000-8000-000000000002`) is the
fixture with items: one note, "Fixture items" (`33333333-3333-4333-8333-333333333333`), with a text
box, an image (a 1 x 1 PNG blob, referenced) and an equation (LaTeX source, no render) next to one
stroke. It is separate from the sample so the sample's note and revision counts, and the web goldens,
stay as they are. Rewrite it with
`SEMPERE_REGENERATE_ITEMS_FIXTURE=1 swift test --filter FixtureTests/testRegenerateItemsFixture`
(`FixtureTests.testItemsFixtureHoldsTextImageAndEquation` and `CLIFlagTests.testItemsFixtureThroughTheCLI` read it).

`sample.sempere` also holds one attachment blob
(`format.md` §8.1) in the lecture's `att/`: the 50 bytes
`Sempere fixture attachment: synthetic, test-only.\n`, type `text/plain`
(kind `bin`, sha256 `ae0a2902…6436`). No revision references it (`items.sempere`
is the vault with a note that has items), so `verify`
lists it as `unreferenced`. Every fixture's `vault.json` is written by `Vault.create` as the
fixture device (the home): wraps for the device and the recovery key, `listTag`, `markersTag` and
the home's signatures (`format.md` §2, §2.1), and no `features` (this version defines none) except
`newer.sempere`'s `["tables"]` (§7.6). Every file is encrypted to the vault identity in one
stanza.

Stroke ids are `f1c70000-0000-4000-8000-0000000001NN`; page ids end in `…001`,
`…002` (lecture) and `…003` (deleted note). All clocks are fixed offsets from
2026-10-04T16:20:00Z.

Recovery without the app:

```bash
cd sample.sempere   # age >= 1.3
jq -r '.keys[] | select(.role == "recovery") | .wrap' vault.json | age -d -i ../sample-recovery.key > /tmp/vault-keys.txt
age -d -i /tmp/vault-keys.txt notes/<noteId>/<file>.age | tail -c +38 | gunzip | jq .
age -d -i /tmp/vault-keys.txt notes/11111111-1111-4111-8111-111111111111/att/*.bin.age | tail -c +46 | head -c 50
age -d keys/recovery-*.key.age           # passphrase: sempere-test; prints the recovery key
```

`sample.key` opens the device's own wrap the same way (`select(.role == "device")`).

## Regenerating

The content is defined in `SampleFixture` in `../FixtureTests.swift`.

```bash
SEMPERE_REGENERATE_FIXTURE=1 swift test --filter FixtureTests/testRegenerateFixture
```

This reuses `sample.key` and `sample-recovery.key` (one that is missing, or a
`sample.key` that is not a device key file, is minted anew; an older plain
`sample.key` keeps its age identity and gains signing keys) and rewrites
`sample.sempere/`. The vault key and age encryption are random, so the
ciphertext bytes, the root, the epoch id and the record's name change on every
regeneration; names of notes and revisions, ids, clocks and the decrypted
JSON do not. `items.sempere` is rewritten with
`SEMPERE_REGENERATE_ITEMS_FIXTURE=1` (above) and `newer.sempere` as below. `testFixtureOpensAndReconstructs` checks that a fresh
generation decrypts to the same revisions as the committed one.

## `newer.sempere`: a vault of a later format version

A synthetic vault as a future Sempere might write it (format.md §7), with
`sample.key`'s device as its home (its recovery key is a throwaway one, not
kept, and it has no passphrase copy): `vault.json` says `format: "sempere/2"`
and `features: ["tables"]`, so this version opens it read-only. Vault id
`5a3b1e00-1000-4000-8000-000000000002`; device `0e0e0e0e` is the "newer" writer.
Written by `NewerFixture.generate` (`Tests/SempereTests/NewerFormatTests.swift`;
regenerate with `SEMPERE_REGENERATE_FIXTURE=1 swift test --filter
NewerFormatTests/testRegenerateNewerFixture`).

| Note | Revisions | What this version shows |
| --- | --- | --- |
| `33333333-…` | a version-1 delta; a delta marked `sempere/2` with `moveStroke` (unknown op), `setMeta` of `color` (unknown register), an `addStroke` that does not decode, an item of kind `hologram`, an unknown envelope field | title "Newer fixture, edited by v2", tag `v2`, 2 strokes, a placeholder item; 3 ops skipped |
| `44444444-…` | one snapshot marked with the unknown feature `tables`, holding a stroke with a bad id, a page without id, unknown `state`, `meta` and page members | title "Newer snapshot", 1 page with 1 stroke; 2 elements skipped |
| `55555555-…` | a version-1 delta; a delta with body version 2 | the first delta only; one unreadable newer revision |

`web/test/golden/newer` holds the CLI's export of these notes, which the web
viewer must reproduce.
