### Added

- Sync carries device changes (key hierarchy KH4): epoch records (`epochs/`), join requests (`joins/`) and the
  recovery key's passphrase copy (`keys/`) reach every target; a later device list is taken once its chain
  verifies (a removal, a handoff, a kit replacement or a takeover), and this device's own files are caught up.
  A list that cannot be verified yet holds every upload back until it can; a device the newest list does not
  hold uploads nothing, keeps pulling, and resumes when a takeover lists it again.
- Files from before a device change that no change sealed are kept aside on arrival, never placed; once their
  writer catches up, the accepted copy replaces the unaccepted one on targets and devices.
- CLI: `devices remove`, `handoff`, `takeover` and `recovery replace` pull from a store vault's targets first
  (`--no-pull`), and `remove` names a device whose last sync is stale; `devices list` shows each device's last
  sync; `devices status` shows this machine's state and exports its own changes no target holds; a joining
  machine takes its approval over a sync.
