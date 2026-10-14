Synthetic video for `VideoProbe`, the CLI tests and the web viewer (ffmpeg's test pattern and a sine tone, no real recordings):

```
F="-hide_banner -loglevel error -y"
ffmpeg $F -f lavfi -i "testsrc=size=160x90:rate=10:duration=1" -f lavfi -i "sine=frequency=440:duration=1:sample_rate=48000" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 32k -ac 1 \
  -metadata "com.apple.quicktime.location.ISO6709=+48.8584+002.2945/" -metadata "com.apple.quicktime.make=TestCam" \
  -movflags use_metadata_tags clip-h264.mp4
ffmpeg $F -i clip-h264.mp4 -c copy -movflags +faststart+use_metadata_tags clip-h264-faststart.mp4
ffmpeg $F -display_rotation 90 -i clip-h264.mp4 -c copy -map_metadata -1 clip-h264-rotated.mp4
ffmpeg $F -f lavfi -i "testsrc=size=128x72:rate=10:duration=0.5" -c:v libx265 -preset ultrafast -tag:v hvc1 -pix_fmt yuv420p -an \
  -metadata location="+48.8584+002.2945/" -movflags +faststart -f mov clip-hevc.mov
ffmpeg $F -f lavfi -i "testsrc=size=64x36:rate=10:duration=0.5" -c:v mpeg4 -an clip-mpeg4.mp4
ffmpeg $F -f lavfi -i "testsrc=size=64x36:rate=10:duration=0.5" -c:v libx264 -an -movflags frag_keyframe+empty_moov clip-fragmented.mp4
ffmpeg $F -i clip-h264.mp4 -frames:v 1 -q:v 5 -map_metadata -1 poster.jpg
```

- `clip-h264.mp4`: `moov` after `mdat`, location and make in `moov/meta` (removed by `VideoMetadata`).
- `clip-h264-faststart.mp4`: the same, `moov` first.
- `clip-h264-rotated.mp4`: track matrix turned 90° counter-clockwise (ffmpeg's convention), i.e. `videoRotation` 270; no metadata.
- `clip-hevc.mov`: QuickTime brand, HEVC (`hvc1`), no sound, location in `moov/udta` (`©xyz`).
- `clip-mpeg4.mp4`: MPEG-4 Part 2 (`mp4v`), refused. `clip-fragmented.mp4`: fragmented (`mvex`), refused.
