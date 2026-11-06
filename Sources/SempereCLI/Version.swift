/// The CLI's version: the single source of truth. `scripts/release-build.sh` (and `release-tag.sh`)
/// refuse a `vX.Y.Z` tag unless it equals `X.Y.Z`; bump it (and `CHANGELOG.md`)
/// in the release PR, before tagging.
let sempereVersion = "1.0.1"
