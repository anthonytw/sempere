# CloudKit spike (phase C0)

Throwaway probe for `docs/design/1.4-cloudkit.md` §12 and §13 (the findings). **Not part of any shipping target**:
nothing under `Apps/` or `Sources/` builds or links it, and `release-check.sh` and the portability checks never read
`tools/`. It runs against the **development** environment of `iCloud.io.github.anthonytw.sempere`, in zones named
`c0-<uuid>` that it deletes, as the test Apple ID signed in on the claude macOS account.

## Pieces

| File | What |
| --- | --- |
| `Sources/Spike.swift` | the probes (one file: Mac Catalyst app, iOS simulator app, or a plain macOS executable) |
| `build.sh` | `catalyst`, `sim`, `cli` builds with `swiftc` (no Xcode project) and signing; run through `~/.claude/scripts/xc-lock.sh` |
| `asc/` | App Store Connect API scripts: `setup.py` (design §11 steps 4, 6, 8), `survey.py` (read-only listing), `remake-appstore-profiles.py` (step 5; **never run**) |
| `schema.ckdb` | the proposed record types (`VaultFile`, `VaultFilePart`), validated with `cktool validate-schema` |

## Rerun

```bash
export S=$(mktemp -d)                                  # your own scratch directory
uv run tools/cloudkit-spike/asc/setup.py --profiles-dir $S   # ids, device, development profiles (additive)
# Mac Catalyst: signed with the Apple Development cert in the claude keychain + the Catalyst development profile
SPIKE_PROFILE=$S/Sempere_Dev_Catalyst.provisionprofile SPIKE_OUT=$S/build \
  ~/.claude/scripts/xc-lock.sh tools/cloudkit-spike/build.sh catalyst
# run it through LaunchServices (a direct exec traps in UIKit); SPIKE_LOG gets every JSON line
XC_KIND=mac ~/.claude/scripts/xc-lock.sh /bin/sh -c \
  "open -W -n --env SPIKE_LOG=$S/run.log --env SPIKE_PROBES=conditional,feed,perf $S/build/Spike.app"
python3 -c 'import json,sys; [print(d["probe"],d["k"],d["v"]) for d in map(json.loads,open(sys.argv[1]))]' $S/run.log
```

`SPIKE_PROBES` (comma list, default `account,conditional,limits,assets,feed,perf`): `account`, `conditional`
(create/replace/delete semantics, races, tombstones), `limits` (batch counts, record sizes, request bytes), `reqbytes`
(where the request byte limit lies), `assets` (`SPIKE_ASSET_MIN_MIB` / `SPIKE_ASSET_MAX_MIB`, 1 MiB to 4 GiB;
`SPIKE_NO_MULTI=1`), `feed` (zone change feed, pages, tokens, deletions, database changes), `enc` (encrypted fields in
`desiredKeys`), `perf` (single-record save throughput at widths 1/4/8/16), `push` (subscriptions and APNs: waits
`SPIKE_PUSH_WAIT` seconds and prints `READY-FOR-EXTERNAL-WRITE` when another device should write; `SPIKE_ZONE` names
the zone to share; `SPIKE_PUSH_BADGE=1` makes the push non-silent), `pushwrite` (the other device: two writes into
`SPIKE_ZONE`), `cleanup` (deletes every `c0-*` zone and subscription; run it after a crashed run).

Simulator: `build.sh sim`, `xcrun simctl clone <base UDID> c0-clone`, boot, `simctl install`, then
`SIMCTL_CHILD_SPIKE_LOG=… SIMCTL_CHILD_SPIKE_PROBES=… xcrun simctl launch <clone> io.github.anthonytw.sempere`.
**Delete the clone afterwards** (`simctl shutdown`, `simctl delete`); never touch the base `sempere-cloudkit` simulator.

CLI bundle (§6.5): `build.sh cli` makes `sempere.app/Contents/MacOS/sempere`; `CLI_PROFILE=<profile>` embeds one,
`CLI_BUNDLE_ID=<id>` sets the bundle id. Run it directly or through a symlink in a `bin/` directory.
Result (design §13.7): with `CLI_BUNDLE_ID=io.github.anthonytw.sempere.cli` and the `Sempere CLI Dev` profile (made after the
container was assigned to the CLI App ID: `asc/setup.py --cli-only --suffix " 3" --profiles-dir $S`; profile names must be
new) it reaches CloudKit. Developer ID: `CLI_DEVID=1 SPIKE_ENV=Production SPIKE_IDENTITY="Developer ID Application: …"
SPIKE_KEYCHAIN=<keychain> CLI_PROFILE=<Developer ID profile>`; not run here (no private key on this seat); run with
`SPIKE_NO_ZONE=1 SPIKE_PROBES=account` so nothing is written to Production.

## Gotchas found while building it (details in the design doc §13)

- Register the Mac by its **Provisioning UDID** (`system_profiler SPHardwareDataType`), never the hardware UUID: the
  API accepts the UUID, and the signed app is then killed with SIGKILL and no message.
- A Catalyst app built with a current SDK needs a `UIApplicationSceneManifest` and a scene delegate or UIKit traps.
- A simulator build takes its entitlements from a `__TEXT,__entitlements` section (`-sectcreate`) and is signed ad hoc
  **without** `--entitlements`; signing the iCloud entitlements into the simulator binary fails to spawn (code 163).
- `CKRecord.ID(recordName:)` with 256 characters raises an Objective-C exception (the limit is 255).
