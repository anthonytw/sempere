### Fixed

- Joining: a device asking to join a vault in iCloud Drive whose `joins` folder was empty never sent its request, and
  its join screen said the request was in the sync target. The request now goes out with the first sync, and the
  screen says it is sent only once a sync has put it there.
