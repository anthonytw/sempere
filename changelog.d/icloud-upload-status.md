### Fixed

- Sync: a vault in iCloud Drive no longer reads "Synced" while iCloud has not uploaded this device's changes. Every file
  the sync wrote counts (settings, device records and summaries too), a file iCloud has not taken in yet waits, and the
  count is checked again between syncs, so the status returns to Synced when iCloud is done. `sempere sync folder` says
  how many files iCloud has not uploaded yet.
