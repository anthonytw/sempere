### Added

- Keys: removing a device starts a new vault key at once (`sempere devices remove`): files from before stay
  readable to every listed device, and what a removed device writes afterwards is set aside, never read.
- Keys: `sempere devices handoff` makes another device the one that manages devices; `sempere devices takeover`
  (also `recovery takeover`) takes over with the recovery kit when that device is lost or stolen; `sempere
  recovery replace` replaces the recovery kit after reviewing every device.
- Keys: a device that missed a key change re-encrypts its own files, voice notes included, from its write
  ledger (`sempere vault catch-up`, also on the first write); `sempere set-aside list|export|keep|clear` shows
  and handles files from before a device change. A removed device is told so (CLI exit code 8).
- Web viewer: reads vaults whose key changed, by the same rule.
