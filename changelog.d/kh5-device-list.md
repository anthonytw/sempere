### Added

- Devices (Settings ▸ Sync & Devices, and the Mac's Vault Keys window): every device of the vault with who added it
  and its last sync, the recovery kit, the history of device changes and Repair. The device that manages devices
  renames, removes and hands that role to another device, and replaces the recovery kit.
- Removing a device warns when it has not synced lately and that it can still reach your storage; for a lost or
  stolen device it offers to remove the devices it added while it managed devices.
- Banners for a takeover with the recovery kit by another device (also a notification), for a device that is no
  longer on the vault's device list (with Export), for sync held back more than a day, and for conflicting device
  lists.
- Repair lists files set aside before a device change (Export, Keep, Clear Superseded, and Keep this device's own
  files from changes a takeover undid) and device lists a sync did not take (Forget).
- CLI: `sempere devices history`, and `sempere set-aside keep --own-dropped`.
