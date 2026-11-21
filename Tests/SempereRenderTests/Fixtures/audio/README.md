Synthetic audio for `WebPageShareTests` (a sine tone, no real recording).

`recorded-times.m4a` was written by AVFoundation with the in-note recorder's settings (AAC, 48 kHz, mono, 64 kb/s): two
segments from `AVAssetWriter` stitched by the same `AVMutableComposition` + `AVAssetExportSession` code as
`RecordingAssembly.merge`. Like the app's recordings, its `mvhd`, `tkhd` and `mdhd` hold the wall-clock time it was
written (2026-11-21), and its `udta/meta/ilst` holds only `iTunSMPB`. A share made without dates must zero those times.
