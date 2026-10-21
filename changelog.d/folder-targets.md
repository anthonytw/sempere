### Added

- Sync targets: a vault can keep a copy in any folder (iCloud Drive, another provider, a drive) and sync with
  it both ways, next to a WebDAV server, as many as you like (File ▸ Sync Targets…, or More ▸ Sync Targets…).
  New Vault can keep a copy in a folder from the start, and Open Vault… asks whether to keep syncing with the
  folder it copies from. Every vault on the device keeps syncing, open or not.
- `sempere store target list|add|remove`, `sempere store sync` and `sempere store import --keep-syncing`: the
  same targets from the command line.

### Changed

- WebDAV vaults are kept with every other vault on the device; those set up by earlier builds move over
  with their sync state. Voice notes go straight into their vault on the device, open or not, and its targets
  upload them.
