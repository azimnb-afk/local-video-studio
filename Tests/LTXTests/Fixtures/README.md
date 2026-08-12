# Synthetic media fixtures

These three small MP4 files are repository-owned, non-person test fixtures.
They contain only FFmpeg `lavfi` test patterns and generated sine-wave audio;
they contain no LTX output, user media, model weights, or real people.

They exercise the real `MediaProbe`, final-assembly, frame-extraction, and
runtime-diagnostics paths in a fresh checkout without a developer-maintained
`/tmp` directory or a network download.

| File | Streams | Purpose |
| --- | --- | --- |
| `video-with-audio-a.mp4` | H.264 video + AAC audio | General metadata, continuity, and diagnostics tests |
| `video-with-audio-b.mp4` | H.264 video + AAC audio | A distinct second usable take |
| `video-only.mp4` | H.264 video | Audio-absent assembly path |

All are 512×320, 24 fps, and approximately one second long. They were
generated for this repository with FFmpeg 8.1.1 using `testsrc2` or
`smptebars`, optional `sine`, H.264, and AAC. The rendered fixture data is
dedicated to this repository under the project MIT license; FFmpeg itself is
not bundled or required to run the tests.
