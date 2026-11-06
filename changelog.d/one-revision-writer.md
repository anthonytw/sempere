### Fixed

- CLI: an edit written next to a revision that cannot be read yet (still arriving, or replaced while being
  read) now sorts after it, as the app's edits already did, instead of losing to it.
- App: a Notability import that stops half way keeps the clock readings it already used, so a later edit
  never sorts before a note it imported.
