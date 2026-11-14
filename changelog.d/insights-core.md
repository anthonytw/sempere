### Added

- Note Insights, part 1 (command line): `sempere insights` makes a short summary, keywords and concepts for each note
  with Apple's on-device model (macOS 26 with Apple Intelligence), finds related notes and builds a map of them with
  Apple's on-device language framework, summarizes notebooks and tags, and titles quick voice notes from their
  transcripts. Everything is made on your devices only, stored encrypted in the vault's new `insights/` folder and
  synced with it; it is off until `sempere settings set insights.enabled true`, and `sempere insights purge` turns it
  off and deletes it. Reading insights (`show`, `related`, `search`, `status`, `map`) works on Linux too. The app's
  part comes in a later release.
