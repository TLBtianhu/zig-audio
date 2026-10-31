# Test fixtures

Generated locally with **ffmpeg n7.1.5** (20260731 build). They are committed
because they are tiny (about 90 KB total, still under the 100 KB budget) and let
CI exercise real encoder output without installing ffmpeg.

No third-party or copyrighted content: every file is a 0.02 s, 440 Hz sine wave.

## Commands

WAV fixtures use this source:

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

FLAC fixtures are **transcoded from the WAV files above** so that the two
decoders can be compared sample for sample without any external tool. The
fixed-predictor trio is encoded with the LPC stage disabled and independent
channels:

```
-lpc_type none -ch_mode indep -max_partition_order 4 -c:a flac
```

| File | Source / additional arguments |
| --- | --- |
| `flac-s16-stereo-44100.flac` | from `wav-pcm16-stereo-44100.wav` |
| `flac-s16-6ch-48000.flac` | from `wav-pcm16-6ch-48000.wav` |
| `flac-s24-stereo-44100.flac` | from `wav-pcm24-stereo-44100.wav`, plus `-sample_fmt s32 -bits_per_raw_sample 24` |
| `flac-s16-mono-8000-lpc.flac` | fresh sine, `-ac 1 -ar 8000 -lpc_type levinson` |
| `flac-s16-stereo-44100-lpc.flac` | from `wav-pcm16-stereo-44100.wav`, plus `-lpc_type levinson -min_prediction_order 32 -max_prediction_order 32 -lpc_coeff_precision 15 -ch_mode mid_side` |

Full example:

```sh
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=0.02" \
  -ac 2 -ar 44100 -c:a pcm_s16le wav-pcm16-stereo-44100.wav
ffmpeg -v error -y -i wav-pcm16-stereo-44100.wav \
  -c:a flac -lpc_type none -ch_mode indep -max_partition_order 4 \
  flac-s16-stereo-44100.flac
ffmpeg -v error -y -i wav-pcm16-stereo-44100.wav \
  -c:a flac -lpc_type levinson -min_prediction_order 32 \
  -max_prediction_order 32 -lpc_coeff_precision 15 -ch_mode mid_side \
  -max_partition_order 4 flac-s16-stereo-44100-lpc.flac
```

## FLAC coverage

| File | Block size | Bits | Channels | Subframes | Status |
| --- | --- | --- | --- | --- | --- |
| `flac-s16-stereo-44100.flac` | 4608 | 16 | 2 | FIXED | decodes |
| `flac-s16-6ch-48000.flac` | 4608 | 16 | 6 | 5 CONSTANT + 1 FIXED | decodes |
| `flac-s24-stereo-44100.flac` | 4608 | 24 | 2 | FIXED | decodes (`>> 8` to i16) |
| `flac-s16-mono-8000-lpc.flac` | 576 | 16 | 1 | LPC | decodes |
| `flac-s16-stereo-44100-lpc.flac` | 882 | 16 | 2 | LPC order 32, mid/side (17-bit side) | decodes |

The 8-bit / 12-bit / 20-bit / wasted-bits / predictor-overflow / Rice-escape
cases cannot be produced by ffmpeg's FLAC encoder, and the official test vector
corpus is not committed. Those cases are therefore built in memory by
`src/flac_build.zig` and compared against ffmpeg's own decoder in
`src/flac_lpc_test.zig` and the other `src/*_test.zig` files.

## What each fixture covers

- WAV: unsigned PCM8, PCM16, PCM24, PCM32, IEEE float32, and 5.1
  `WAVE_FORMAT_EXTENSIBLE`.
- FLAC: 16-bit stereo, 16-bit 5.1, 24-bit stereo, plus two LPC files (8 kHz mono
  and 44.1 kHz stereo with order-32 mid/side prediction). The 16/24-bit files
  and the stereo LPC file decode to exactly the same i16 samples as their WAV
  sources, which is checked on every CI run.

The live ffmpeg integration tests in `src/ffmpeg_test.zig` generate equivalent
files through a pipe, where ffmpeg writes WAV `data` size `0xFFFFFFFF` and FLAC
`total_samples = 0`; both exercise the "unknown length" paths.
