### Added

- CLI: `sempere vault recipients add|remove|replace|repair` take `--compromised` ("my key may be
  compromised") and `--late-file-window DAYS`, recorded in the key change's journal for devices that
  sync; `--json` reports them as `mode` and `lateFileWindowDays`.

### Changed

- Sync: a rewrap journal this device refuses is never uploaded, and a received `vault.json` that lists
  fewer devices under the same vault secret is not taken (an older list, or another device's concurrent
  addition).
