### Fixed

- Quick voice notes: Control Center, the Action button and Siri record in the background on an iPhone
  again. The audio session is now made active before the Live Activity starts (iOS refused it right after,
  "cannot interrupt others", and the app opened instead), and a background start that is still refused
  records mixed with other audio.
- Quick voice notes: a voice note cut off by a restart, a force quit or a crash is saved, up to its last
  second, the next time Sempere runs or the device is unlocked, and the app says so. Its audio used to be
  unreadable and was kept on the device without a note.
- Quick voice notes: Siri no longer says Sempere may not use the microphone after a restart; when the
  permission cannot be confirmed in the background the voice note records in the app. Before the first
  unlock Siri says to unlock once.
- Quick voice notes: the Live Activity of a recording whose app was force quit says "Voice note
  interrupted" and opens Sempere, which ends it and saves the recording; Stop on such an activity saves it too.

### Changed

- Voice notes from the inbox show their recording on the page with its transcript, as a recording made in
  a note does (`sempere inbox import` too).
