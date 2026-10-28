# Demo vault: sources and licenses

`make-demo-vault.py` downloads these at build time (pinned URLs, checked against the SHA-256 sums in
`assets.json`); none of them is committed (the two voice memos, below, are). Every note's text, handwriting, drawings, equations and the problem
set PDF are original content written for the demo (scenes.py), released with this repository.

## Fonts (handwriting)

The handwriting is traced from two Google Fonts families, converted to pen strokes (hand.py). Both are under the
SIL Open Font License 1.1; the converted strokes are a use of the fonts, and the fonts themselves are not
redistributed in the vault.

| Font | Use | Copyright | License | Source |
| --- | --- | --- | --- | --- |
| Caveat (variable, `Caveat[wght].ttf`) | School notes | Copyright 2014 The Caveat Project Authors (https://github.com/googlefonts/caveat) | SIL OFL 1.1 | google/fonts @ e7db6ca, `ofl/caveat/` |
| Kalam Regular | Personal notes | Copyright (c) 2014, Indian Type Foundry | SIL OFL 1.1 | google/fonts @ e7db6ca, `ofl/kalam/` |

## Pictures and video (NASA)

NASA material is not protected by copyright in the United States and may be used without permission
(NASA Images and Media Usage Guidelines, https://www.nasa.gov/nasa-brand-center/images-and-media/). NASA asks
that it be credited and that its use not imply endorsement; nothing here does. All items are from the NASA Image
and Video Library (https://images.nasa.gov), by NASA id.

| File | NASA id | Title | Credit | Used in |
| --- | --- | --- | --- | --- |
| `artemis-ii-launch-causeway.mp4` (22 s cut, re-encoded) | `KSC ART II Cause Way Launch low angle` | Artemis II launch, Causeway slow motion (Apr 1, 2026) | NASA/Sam Lott | Kepler's Laws, page 2 |
| `moon-artemis-ii.jpg` | `Artemis II at the pad Full Snow Moon 02012026_6` | Full Moon Rising Over Full Artemis II Stack at Launch Pad 39B | NASA/Sam Lott | Kepler's Laws, page 2 |
| `saturn-PIA14934.jpg` | `PIA14934` | A Splendor Seldom Seen (Cassini) | NASA/JPL-Caltech/Space Science Institute | Kepler's Laws |
| `phytoplankton-iceland.jpg` | `GSFC_20171208_Archive_e001018` | Phytoplankton bloom off Iceland (MODIS) | NASA/GSFC/Jeff Schmaltz/MODIS Land Rapid Response Team | Photosynthesis |
| `aurora-iss072e159172.jpg` | `iss072e159172` | The aurora borealis blankets the Earth (ISS, Oct 30, 2024) | NASA | Iceland Ring Road |
| `grand-canyon-iss074e0208838.jpg` | `iss074e0208838` | The Grand Canyon pictured from the International Space Station (Jan 26, 2026) | NASA | Grand Canyon Weekend |
| `zinnias-KSC-20181127-PH_JBS01_0005.jpg` | `KSC-20181127-PH_JBS01_0005` | Space Zinnias: Growing Seeds from Space | NASA/Ben Smegelsky | Spring Bed Plan |

## Tools

Equations and the problem set are typeset with pdflatex (TeX Live; the output is not covered by TeX's
licenses) and outlined with Ghostscript. Star positions in the Night Sky Log are rounded public catalog values
(J2000 right ascension and declination, visual magnitude).

## Voice memos (synthetic speech)

Two short voice notes are committed in `audio/` (the only media here that is not downloaded). The scripts are
original text written for the demo (the `script` fields in `assets.json`, also each recording's transcript), spoken
by the Kokoro-82M text-to-speech model (Apache-2.0, https://github.com/hexgrad/kokoro, served by Kokoro-FastAPI) and
converted to AAC-LC `.m4a` with `afconvert -f m4af -d aac -b 64000`. The audio is synthetic: no real person's voice
was recorded. Both files are released with this repository; their SHA-256 sums are in `assets.json`.

| File | Voice | Length | Used in |
| --- | --- | --- | --- |
| `audio/focaccia-memo.m4a` | `af_heart` | 19.5 s | Sunday Focaccia |
| `audio/kepler-recap.m4a` | `am_michael` | 26.9 s | Kepler's Laws, page 1 |
