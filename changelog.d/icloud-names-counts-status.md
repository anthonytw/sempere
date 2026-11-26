### Fixed

- iCloud: a vault keeps its name when its iCloud target is removed and added again (a name now beats none when only the name
  differs, in either direction), and a vault opened from iCloud is named as it was listed, so Open Vault shows one name.
- The iCloud target is called "iCloud" everywhere (Sync Targets, New Vault, messages, `sempere` help); the folder target in iCloud
  Drive keeps its name.
- "Uploading X of M" keeps its count across the runs a join check stops, counts files the target already held as done, and never shows
  more than the total.
- The sync status no longer flashes between "syncing" and another line when a join check stops the run going; the last progress stays
  until the next run reports its own.
