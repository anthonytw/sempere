### Changed

- The sync bar at the bottom of the note list now appears only when something is wrong (a refused password or
  certificate, a sync folder gone or not writable, files that failed, a device-list conflict, an upload problem that
  lasts, a sync target that could not be reached for a week while the device was online). Syncing, synced, offline
  and waiting for iCloud show no bar; each target's status stays in Sync Targets….

### Fixed

- Sync: iCloud Drive being slow to upload no longer warns that iCloud storage may be full. An upload error shows only
  once it has lasted about ten minutes, and "storage is full" only when iCloud says so; `sempere sync folder` prints
  such a lag as `provider upload delayed`.
