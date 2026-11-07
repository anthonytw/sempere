### Changed

- CLI: `store target add --folder PATH` places the vault's copy where the app's Add Folder… does. A `….sempere`
  folder is the copy itself, as before, and so is a folder that already holds this vault (a target 1.0.0 synced
  straight into it: re-adding it on another machine, or after `target remove`, joins that copy). Any other folder
  now gets the copy in `PATH/<name>.sempere` (or the next free `<name> N.sempere`), instead of the vault's files
  going straight into `PATH`. A folder holding another vault, a `….sempere` folder holding other files, and a cloud
  placeholder not downloaded are refused when the target is added (exit 1), as in the app.
- CLI: `store import --keep-syncing` follows the same rule (the source, which holds the vault, stays the target).
