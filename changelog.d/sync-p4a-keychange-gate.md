### Added

- Sync: a device removed from a vault notices at its next sync and stops syncing that vault for good (no
  upload, whatever a server later shows); its copy stays readable. `sempere sync webdav` exits 8, lists the
  files it wrote that no server holds, and `--export-unsynced FOLDER` copies them out.
- CLI: `sempere vault recipients remove` asks for `--accept-unsynced`: a vault does not record when the
  removed key's device last synced, and every key change takes effect at once.

### Changed

- Sync: a rewrap journal this device refuses is never uploaded, and a received `vault.json` that lists
  fewer devices under the same vault secret is not taken (an older list, or another device's concurrent
  addition).
