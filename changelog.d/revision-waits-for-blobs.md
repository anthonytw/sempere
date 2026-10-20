### Fixed

- Sync no longer uploads a note's new revisions in a run where one of the note's attachments failed to
  upload (or the server's attachment listing failed): before, another device could receive a revision
  whose image or file was missing, for good if the writing device stopped syncing. The revisions go up
  with the attachments on the next run.
