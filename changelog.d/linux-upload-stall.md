### Fixed

- Linux CLI: a WebDAV upload cut by a connection reset now fails within about 15 seconds (it waited for the
  60-second idle timeout). `SEMPERE_WEBDAV_BODY_STALL` sets the limit in seconds.
