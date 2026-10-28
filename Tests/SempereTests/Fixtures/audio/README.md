Synthetic audio for `AudioProbe` and the CLI tests (a sine tone, no real recordings):

```
ffmpeg -f lavfi -i "sine=frequency=440:duration=2.5:sample_rate=48000" -ac 1 -c:a aac -b:a 64k -map_metadata -1 -fflags +bitexact -flags:a +bitexact tone-aac.m4a
ffmpeg -f lavfi -i "sine=frequency=330:duration=1:sample_rate=44100" -ac 2 -c:a alac -map_metadata -1 -fflags +bitexact -flags:a +bitexact tone-alac.m4a
ffmpeg -i tone-aac.m4a -c copy -movflags +faststart -map_metadata -1 -fflags +bitexact tone-aac-faststart.m4a
```

`tone-aac.m4a` has its `moov` box after `mdat` (as AVAudioRecorder writes it), `tone-aac-faststart.m4a` before it.
