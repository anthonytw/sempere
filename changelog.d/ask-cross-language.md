### Fixed

- Ask: a question in a language none of your notes is written in (Spanish about English notes) is translated on the
  device into your notes' language to find them, and the answer comes back in the question's language. The answer is
  checked in the notes' language, then its numbers, dates, codes and names are checked again after translation; a
  sentence that changed one is dropped. Without the on-device model the result says the question could not be
  translated instead of finding nothing. A question's language is recognized from its own words (among the languages the
  on-device model supports), so a Spanish question is taken for Spanish even on an English device with English notes;
  one-word queries and names still fall back to your notes' and the device's languages.
- Ask: an answer no longer repeats a sentence (repeats are removed and their sources merged), and "Other matching
  notes" lists only notes about as relevant as the ones the answer used, not every note.
