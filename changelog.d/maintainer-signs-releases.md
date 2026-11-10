### Changed

- Releases from 1.1.0 on: the maintainer signs each release tag and its `SHA256SUMS` personally, with their own SSH key
  after the build. SECURITY.md lists the public key and its fingerprint (`packaging/allowed_signers`), and
  the release scripts refuse a tag that key did not sign.
