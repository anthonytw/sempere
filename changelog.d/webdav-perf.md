### Changed

- WebDAV sync: files the server lacks are uploaded `--jobs` at a time (default 6), a note's attachments
  before its revisions, still only ever created on the server, never replaced; a first upload or a push
  after an import no longer waits on one round trip after another.
- WebDAV sync: on a server seen to answer `PROPFIND` `Depth: infinity` in full (checked against the
  one-by-one listings first, and again daily), every note folder is listed with one request: an idle run
  of a 640-note vault makes 4 requests instead of 686. Servers that refuse it are remembered and listed
  as before; `--no-deep-listing` turns it off.

