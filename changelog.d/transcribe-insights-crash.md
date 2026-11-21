### Fixed

- CLI: `sempere transcribe --again --insights` (and the note-and-recording form) no longer fails with "Can't read a
  value from a parsable argument definition" after storing the transcript; the insights are made again and the derived
  title stays. The command now takes `--no-cache` like the other commands that read notes.
- Docs: the language-change catch-up of Note Insights says what it does (every note whose summary is in another
  language is made again in one `update`; `--limit` caps it) instead of "a few per update".
- Web: the share-file smoke test no longer fails in WebKit on Playwright's own screenshot stylesheet.
