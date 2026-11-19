### Fixed

- Notes: deleting, renaming or moving notes while the daily cleanup of old versions runs is written at once. The cleanup
  held every edit until it had gone through the whole vault, so notes deleted meanwhile could come back if the app was
  closed or suspended before it finished.
