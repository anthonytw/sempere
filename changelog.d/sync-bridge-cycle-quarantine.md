### Fixed

- Sync: two devices that both sync the same two servers no longer pass a thinned revision back and
  forth for ever; a deletion each device settled with a server is remembered, and a copy that comes
  back is judged as a deletion again.
- Sync: a file quarantined again under the same path no longer replaces the copy kept before; every
  distinct copy is kept (up to 16 per path).
- Sync: a server that changes `vault.json`'s ETag without changing its bytes no longer makes a
  conflict copy identical to the server's copy.
