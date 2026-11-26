### Fixed

- iCloud (CloudKit): vaults are listed by their own names. A new vault carries its name into iCloud, and a vault that gets an iCloud
  sync target (or was moved to iCloud before) gets its name written once, while it is open and unlocked. Open Vault ▸ From iCloud also
  shows when each vault last changed.
- Open Vault ▸ From iCloud: any listed vault can be deleted (swipe or context menu, with a confirmation that says when no copy of it is
  left), so a vault another device removed, or an empty one, no longer stays in the list for good. Opening a large vault shows how many
  files have come down.
- Sync Targets: the status line counts a run as it goes ("Uploading 120 of 340 files to iCloud…", "Downloading 40 of 90 files…"), and a
  failed iCloud attempt is named beside "N changes not synced yet" instead of staying silent.
- Joining a device through iCloud no longer waits behind a long first upload: Add Device and Join This Device stop the run going and
  carry the request and the approval at once; the upload continues afterwards.
