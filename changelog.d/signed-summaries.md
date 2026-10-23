### Changed

- Sync: each device now signs its published note summaries (`summaries/<device>.sealed`), and other
  devices order and accept only copies signed by that device. Another device, a removed device or
  the storage server can no longer hold back or replace a device's summaries; files written before
  this change are ignored until their device writes again.
