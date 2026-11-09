### Added

- CLI: `sempere notes move` takes several notes: `notes move ID|TITLE... (NOTEBOOK | --none)`. Every note is resolved before
  anything is written, so one that does not resolve moves nothing. `--json` prints one entry per note.
