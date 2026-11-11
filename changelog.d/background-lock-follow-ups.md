### Fixed

- iPhone and iPad: an import or a restore that was still running when Sempere had been in the background for longer
  than iOS allows now stops and adds nothing, instead of possibly placing an incomplete copy in the app. The vault or
  backup it came from is never changed; run it again.
- iPhone and iPad: when iOS starts Sempere in the background, a note it reopens is no longer read for handwriting
  search until Sempere is on screen, so no "could not save" message about recognized text waits for you later.
