### Changed

- WebDAV sync: the first sync on a device, and the daily re-check, of a large vault no longer list every note
  folder one by one to confirm that the server answers `PROPFIND` `Depth: infinity` in full. A sample of 16 folders
  (plus their `att/`) is compared with the tree and the rest is taken from it in the same run: a first pull or
  idle run of a 640-note vault makes about 20 listing requests instead of 686. A server whose tree differs from
  the sample is listed one by one, as before.
