### Fixed

- Web page shares made without dates (the app's Web Page (Encrypted) export and `sempere share` without `--dates`) no longer
  carry a recording's dates: an MP4 recording's container times are zeroed and its tags removed, and a transcript's creation
  time is left out. Recognized text and transcripts no longer name the recognizer.
