# Sempere test fixture vault

**TEST-ONLY. `sample.key` is a throwaway identity committed on purpose so that
tests (and the CLI task) can open `sample.sempere`. Never encrypt anything real
to its recipient.**

| File | What it is |
| --- | --- |
| `sample.key` | Plain-text post-quantum age identity (`age-keygen -pq` style), test-only |
| `sample.sempere/` | A small vault in the format of `docs/format.md` |
| `sample.sempere/keys/age1pq-<sha256>.key.age` | The same identity, passphrase-wrapped: passphrase `sempere-test`, scrypt work factor 15 |
| `legacy.key`, `legacy.sempere/` | The same notes in a **legacy** X25519 vault (classic key, `keys/<recipient>.key.age`, same passphrase): migrate-only (format.md §3.3.2), the input of the migration tests |
| `notability/synthetic.note` | The importer tests' synthetic Notability note (`SyntheticNote.package()` in `Tests/SempereImportTests`): no personal data. The app's Notability import tests read it |

`*.key` is git-ignored repository-wide; `sample.key` and `legacy.key` were
added with `git add -f`.

## Contents

Vault id `5a3b1e00-1000-4000-8000-000000000001`, created
2026-10-04T16:20:00Z, one recipient. Devices `a1b2c3d4` (A) and `99ee00ff` (B).

| Note | Revisions | Reconstructs to |
| --- | --- | --- |
| `11111111-1111-4111-8111-111111111111` | A1, B1, B2 deltas; A2 snapshot; A3 delta after it | title "Fixture lecture", tags `["fixture"]`, ruled paper, 2 pages with 2 strokes each |
| `22222222-2222-4222-8222-222222222222` | A1 delta, B1 `deleteNote` | title "Fixture deleted", `deleted: true`, 1 page with 1 stroke |

`items.sempere` (same key as the sample, vault id `5a3b1e00-1000-4000-8000-000000000002`) is the
fixture with items: one note, "Fixture items" (`33333333-3333-4333-8333-333333333333`), with a text
box, an image (a 1 x 1 PNG blob, referenced) and an equation (LaTeX source, no render) next to one
stroke. It is separate from the sample so the sample's note and revision counts, and the web goldens,
stay as they are. Rewrite it with
`SEMPERE_REGENERATE_ITEMS_FIXTURE=1 swift test --filter FixtureTests/testRegenerateItemsFixture`
(`FixtureTests.testItemsFixtureHoldsTextImageAndEquation` and `CLIFlagTests.testItemsFixtureThroughTheCLI` read it).

`sample.sempere` (not `legacy.sempere`) also holds one attachment blob
(`format.md` §8.1) in the lecture's `att/`: the 50 bytes
`Sempere fixture attachment: synthetic, test-only.\n`, type `text/plain`
(kind `bin`, sha256 `ae0a2902…6436`). No revision references it yet (`items.sempere`
is the vault with a note that has items), so `verify`
lists it as `unreferenced`, and `vault.json` has `features: ["attachments",
"recipients-tag", "signed-secret-link", "markers-tag"]`, a `recipientsTag` and a `markersTag`
(`format.md` §2.1; they were added to the committed file, so copies of the fixture share a vault id
without looking like a downgrade). Tests that need a vault written before §2.1 take the tags and the
features out of a copy (`FixtureVault.copySample`). `newer.sempere`'s `vault.json` carries a
`markersTag` too, as a newer writer's would (§7.6). `legacy.sempere`
has no tag: its migration writes one.

Stroke ids are `f1c70000-0000-4000-8000-0000000001NN`; page ids end in `…001`,
`…002` (lecture) and `…003` (deleted note). All clocks are fixed offsets from
2026-10-04T16:20:00Z.

Recovery without the app:

```bash
age -d -i sample.key sample.sempere/notes/<noteId>/<file>.age | tail -c +38 | gunzip | jq .   # age >= 1.3
age -d -i legacy.key legacy.sempere/notes/<noteId>/<file>.age | tail -c +38 | gunzip | jq .
age -d sample.sempere/keys/*.key.age     # passphrase: sempere-test
age -d -i sample.key sample.sempere/notes/11111111-1111-4111-8111-111111111111/att/*.bin.age | tail -c +46 | head -c 50
```

## Regenerating

The content is defined in `SampleFixture` in `../FixtureTests.swift`.

```bash
SEMPERE_REGENERATE_FIXTURE=1 swift test --filter FixtureTests/testRegenerateFixture
```

This reuses `sample.key` and `legacy.key` (delete one first to mint a new
identity) and rewrites `sample.sempere/` and `legacy.sempere/`. age encryption is randomized, so the ciphertext bytes and
the vault secret change on every regeneration; names, ids, clocks and the
decrypted JSON do not. `testFixtureOpensAndReconstructs` checks that a fresh
generation decrypts to the same revisions as the committed one.

## `newer.sempere`: a vault of a later format version

A synthetic vault as a future Sempere might write it (format.md §7), encrypted
to `sample.key`: `vault.json` says `format: "sempere/2"` and `features:
["tables"]`, so this version opens it read-only. Vault id
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
