### Fixed

- Sync: devices that sync two places no longer pass two copies of another device's published
  summaries back and forth for ever (a sync that never went quiet); each copy carries its writer's
  version, and an older one never replaces a newer one.
