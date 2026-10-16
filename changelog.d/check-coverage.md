### Fixed

- WebDAV sync: a device that had pulled a recipient change's `rewrap-journal.json` no longer uploads it
  again after the change finished and the server's copy was removed (two devices then rejected each
  other's stale copy on every run).
