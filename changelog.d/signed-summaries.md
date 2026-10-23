### Changed

- Sync: each device now signs its published note summaries (`summaries/<device>.sealed`), and other
  devices order and accept only copies signed by that device. Another device, a removed device or
  the storage server can no longer forge or alter a device's summaries (a storage server can still
  serve an older genuine copy until a newer one is synced back); files written before this change
  are ignored until their device writes again.
- Devices: approving a device whose id was ever used by another device of the vault is refused (the
  joining device generates another key), and a takeover refuses to keep two devices with one id.
