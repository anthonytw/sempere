# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the CLI's
version (`Sources/SempereCLI/Version.swift`) follows [Semantic Versioning](https://semver.org/).
The section for a version is the body of its GitHub Release (`docs/releasing.md`).

## [Unreleased]

## [1.0.1] - 2026-11-06

### Fixed

- CLI on Linux: the release binary is fully static (built with Swift's Static Linux SDK) and runs on any
  distribution, including Debian 12, Ubuntu 22.04, Ubuntu 25.10 and 26.04 and Alpine. 1.0.0's binary
  needed glibc 2.38 or later and the system's libcurl and `libxml2.so.2`.

## [1.0.0] - 2026-11-05

Initial release.

[Unreleased]: https://github.com/anthonytw/sempere/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/anthonytw/sempere/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/anthonytw/sempere/releases/tag/v1.0.0
