### Changed

- Note Insights: tuned on a real handwritten-notes library. Far more notes keep their summary (the fact check no longer
  drops a sentence for one inferred topic word, but still drops sentences about things a note never mentions, about
  its form rather than its subject, or in LaTeX); keywords no longer turn correctly spelled words into other words
  (`consent` into `content`) and leave out unreadable fragments and terms like "symbols"; related notes use the
  on-device vectors even when a few notes hold only equations; long PDFs are read in at most eight evenly spaced parts;
  a runaway answer from the model ends at once instead of after minutes; voice-note titles that list things are
  shortened instead of refused. Existing summaries are made again (the prompt changed).
