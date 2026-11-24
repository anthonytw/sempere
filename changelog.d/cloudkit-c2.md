### Added

- iCloud (CloudKit) sync target: the sync engine now talks to your private iCloud database. On a Mac, `sempere store target add VAULT --cloudkit` adds it, and the macOS command-line tool ships as a signed and notarized `sempere.app` bundle that Homebrew links `bin/sempere` to (a build from source says that iCloud is not available). In the app, Sync Targets has an Add iCloud (CloudKit) button; the full design of the screens follows.
