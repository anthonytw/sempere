### Added

- CLI: `sempere sync folder PATH` syncs a vault two ways with a copy in a folder (iCloud Drive, another
  provider, a USB drive or a share), with the same rules and checks as `sync webdav`. In a provider's
  folder, evicted files are asked for and waited for (`--wait`), never taken as missing, and the
  provider's conflict versions are merged or kept as conflict copies, so no version picker appears.
