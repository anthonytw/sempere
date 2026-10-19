### Fixed

- Mac: every folder picker the app writes into (New Vault's location, the backup folder, Restore from Backup's
  location, Export to Folder) has New Folder: it is AppKit's open panel with folder creation on, which UIKit's
  picker leaves off.
- Backups: a folder that cannot take the backup (another vault's backup, a vault, the open vault) and a failed
  Back Up Now or Verify Backup are shown as an alert, not a line under the section.
- Backups: Verify Backup lists at most 100 problems, in a box that scrolls, then "…and N more."
- iPad: AutoFill's Strong Password fills both passphrase fields of New Vault (they are one row now).

### Changed

- Sidebar: the Inbox (where quick voice notes land) is listed with All Notes and Favorites, not among the notebooks.
- Sidebar: a nested notebook's menu has Move to Top Level, and a notebook dropped on the Notebooks header goes to
  the top level.
