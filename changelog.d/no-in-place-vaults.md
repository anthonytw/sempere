### Removed

- iCloud Drive and other providers: vaults are no longer read in place. Every vault is an in-app copy; a
  folder in iCloud Drive is copied in (and may stay a sync target), and an older recent of one is copied in
  when chosen.
- WebDAV: the "Download Attachments in the Background" setting (the sync always downloads every attachment).

### Changed

- WebDAV: while a vault joined from a server is still downloading, the list's bar shows how far it got, and
  opening a note not downloaded yet waits a bounded time with a Cancel.
