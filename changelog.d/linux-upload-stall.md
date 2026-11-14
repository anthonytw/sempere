### Fixed

- Linux CLI: a WebDAV upload cut by a connection reset on a kept-alive connection failed after the 60-second idle
  timeout; it now fails at once (or is retried with its whole body), and a reset counts as a lost connection.
