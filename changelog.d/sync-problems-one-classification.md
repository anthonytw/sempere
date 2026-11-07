### Changed

- CLI: `store sync` records a target's last successful sync by the app's rule: a run cut short after it moved
  files (the link lost midway) is progress, not a last success, and the next `store sync` continues it.
- CLI: `webdav check` and `store target add --webdav --check` report the same problem and message as the app's
  Test Connection and Add WebDAV Server…; control characters in the server's error message are escaped.
