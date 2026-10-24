### Added

- Re-encrypt everything (key hierarchy KH6): on the home device, `sempere vault reencrypt` makes a new vault key
  and a new recovery key, re-encrypts every note, attachment, notebook record, quick capture and the shared
  settings under it (each copy checked before the old one goes), carries the new copies to every sync target,
  confirms each target and finishes: nothing in the vault, on a target or on a device, opens with the old kit or an
  earlier key afterwards. It survives crashes, locks and lost networks (`--resume`), removals and a handoff during
  it, and a device that was offline the whole time. `--status` shows where it stands. In the app: Devices ▸ Re-encrypt Everything…
  on the device that manages devices, with a progress sheet.

### Fixed

- A recovery-kit replacement on a device that had taken over the vault made the vault refuse its own device list
  at the next open.
