/// The CLI's version: the single source of truth. `.github/workflows/release.yml`
/// fails a `vX.Y.Z` tag build unless it equals `X.Y.Z`; bump it (and `CHANGELOG.md`)
/// in the release PR, before tagging.
let sempereVersion = "1.0.0"
