# Test fixtures

Generated locally with **ffmpeg n7.1.5** (20260731 build) from a sine wave. They
are committed because they are tiny (about 72 KB total, well under the 100 KB
budget) and let CI exercise real encoder output without installing ffmpeg.

No third-party or copyrighted content: every file is a 0.02 s, 440 Hz sine wave.

## Commands

All commands use this source:

```
-f lavfi -i "sine=frequency=440:duration=0.02"
```

| File | Additional ffmpeg arguments |
| --- | --- |
| `wav-pcm16-stereo-44100.wav` | `-ac 2 -ar 44100 -c:a pcm_s16le` |
| `wav-pcm8-mono-44100.wav` | `-ac 1 -ar 44100 -c:a pcm_u8` |
| `wav-pcm24-stereo-44100.wav` | `-ac 2 -ar 44100 -c:a pcm_s24le` |
| `wav-pcm32-stereo-44100.wav` | `-ac 2 -ar 44100 -c:a pcm_s32le` |
| `wav-f32-stereo-44100.wav` | `-ac 2 -ar 44100 -c:a pcm_f32le` |
| `wav-pcm16-6ch-48000.wav` | `-ac 6 -ar 48000 -c:a pcm_s16le` |
| `flac-s16-stereo-44100.flac` | `-ac 2 -ar 44100 -c:a flac` |
| `flac-s16-mono-8000.flac` | `-ac 1 -ar 8000 -c:a flac` |
| `flac-s16-6ch-48000.flac` | `-ac 6 -ar 48000 -c:a flac` |
| `flac-s24-stereo-96000.flac` | `-ac 2 -ar 96000 -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac` |

## FLAC coverage

ffmpeg's FLAC encoder does not expose a block-size option; it chooses the block
size from the sample rate. These fixtures therefore cover three different
STREAMINFO block sizes as well as three bit depths and channel counts:

| File | Block size (STREAMINFO) | Bits | Channels |
| --- | --- | --- | --- |
| `flac-s16-stereo-44100.flac` | 4608 | 16 | 2 |
| `flac-s16-mono-8000.flac` | 576 | 16 | 1 |
| `flac-s16-6ch-48000.flac` | 4608 | 16 | 6 |
| `flac-s24-stereo-96000.flac` | 8192 | 24 | 2 |

The 8-bit / 12-bit / 20-bit / wasted-bits / predictor-overflow cases come from
the official test vectors (see `tools/fetch-vectors.ps1`), not from these tiny
fixtures.

Full example:

```sh
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=0.02" \
  -ac 2 -ar 44100 -c:a pcm_s16le wav-pcm16-stereo-44100.wav
```

## What each fixture covers

- WAV: unsigned PCM8, PCM16, PCM24, PCM32, IEEE float32, and 5.1
  `WAVE_FORMAT_EXTENSIBLE`.
- FLAC: mono/stereo/5.1, 8 kHz / 44.1 kHz / 48 kHz / 96 kHz, 16-bit and 24-bit.
  The FLAC decoder is the next round; current tests only verify `probe()` and
  the explicit "not implemented yet" error.

The live ffmpeg integration tests in `src/ffmpeg_test.zig` generate equivalent
files through a pipe, where ffmpeg writes `data` size `0xFFFFFFFF` (the
streaming path).
