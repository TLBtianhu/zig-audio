//! Tests against small, committed ffmpeg-generated fixtures. Unlike the live
//! ffmpeg tests these run on every CI platform and without any external tools.
//!
//! The files are tiny (0.02 s of a 440 Hz sine) and live in src/fixtures/,
//! with the exact generation commands in src/fixtures/README.md.

const std = @import("std");
const root = @import("root.zig");
const compare = @import("compare.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

const WavCase = struct {
    name: []const u8,
    bytes: []const u8,
    channels: u16,
    sample_rate: u32,
    bits: u16,
    frames: u64,
};

const wav_cases = [_]WavCase{
    .{
        .name = "pcm16 stereo",
        .bytes = @embedFile("fixtures/wav-pcm16-stereo-44100.wav"),
        .channels = 2,
        .sample_rate = 44_100,
        .bits = 16,
        .frames = 882,
    },
    .{
        .name = "pcm8 mono",
        .bytes = @embedFile("fixtures/wav-pcm8-mono-44100.wav"),
        .channels = 1,
        .sample_rate = 44_100,
        .bits = 8,
        .frames = 882,
    },
    .{
        .name = "pcm24 stereo",
        .bytes = @embedFile("fixtures/wav-pcm24-stereo-44100.wav"),
        .channels = 2,
        .sample_rate = 44_100,
        .bits = 24,
        .frames = 882,
    },
    .{
        .name = "pcm32 stereo",
        .bytes = @embedFile("fixtures/wav-pcm32-stereo-44100.wav"),
        .channels = 2,
        .sample_rate = 44_100,
        .bits = 32,
        .frames = 882,
    },
    .{
        .name = "float32 stereo",
        .bytes = @embedFile("fixtures/wav-f32-stereo-44100.wav"),
        .channels = 2,
        .sample_rate = 44_100,
        .bits = 32,
        .frames = 882,
    },
    .{
        .name = "pcm16 5.1",
        .bytes = @embedFile("fixtures/wav-pcm16-6ch-48000.wav"),
        .channels = 6,
        .sample_rate = 48_000,
        .bits = 16,
        .frames = 960,
    },
};

const FlacCase = struct {
    name: []const u8,
    bytes: []const u8,
    channels: u16,
    sample_rate: u32,
    bits: u16,
    frames: u64,
    /// WAV fixture holding exactly the samples this FLAC file encodes, when
    /// there is one. Comparing both decoders is a fully offline exactness test.
    wav_source: ?[]const u8 = null,
};

// Regenerated for the FLAC Stage A round: ffmpeg was told to use fixed
// predictors and independent channels so these files stay inside the
// supported subset. The LPC file is the negative case.
const flac_cases = [_]FlacCase{
    .{
        .name = "flac s16 stereo",
        .bytes = @embedFile("fixtures/flac-s16-stereo-44100.flac"),
        .channels = 2,
        .sample_rate = 44_100,
        .bits = 16,
        .frames = 882,
        .wav_source = wav_cases[0].bytes,
    },
    .{
        .name = "flac s16 6ch",
        .bytes = @embedFile("fixtures/flac-s16-6ch-48000.flac"),
        .channels = 6,
        .sample_rate = 48_000,
        .bits = 16,
        .frames = 960,
        .wav_source = wav_cases[5].bytes,
    },
    .{
        .name = "flac s24 stereo",
        .bytes = @embedFile("fixtures/flac-s24-stereo-44100.flac"),
        .channels = 2,
        .sample_rate = 44_100,
        .bits = 24,
        .frames = 882,
        .wav_source = wav_cases[2].bytes,
    },
    .{
        .name = "flac s16 mono 8k (LPC)",
        .bytes = @embedFile("fixtures/flac-s16-mono-8000-lpc.flac"),
        .channels = 1,
        .sample_rate = 8_000,
        .bits = 16,
        .frames = 160,
    },
};

test "committed ffmpeg WAV fixtures decode fully" {
    for (wav_cases) |case| {
        try testing.expectEqual(root.Format.wav, root.probe(case.bytes[0..12]).?);

        var reader = std.Io.Reader.fixed(case.bytes);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();

        try testing.expectEqual(case.channels, dec.info.channels);
        try testing.expectEqual(case.sample_rate, dec.info.sample_rate);
        try testing.expectEqual(case.bits, dec.info.bits_per_sample);
        try testing.expectEqual(@as(?u64, case.frames), dec.info.total_frames);

        var out: [4096]i16 = undefined;
        var frames: u64 = 0;
        var saw_signal = false;
        while (true) {
            const n = try dec.read(&out);
            if (n == 0) break;
            frames += n / case.channels;
            for (out[0..n]) |sample| {
                if (sample != 0) saw_signal = true;
            }
        }
        try testing.expectEqual(case.frames, frames);
        try testing.expect(saw_signal);
    }
}

test "committed fixed-predictor FLAC fixtures decode fully" {
    for (flac_cases[0..3]) |case| {
        try testing.expectEqual(root.Format.flac, root.probe(case.bytes[0..12]).?);

        var reader = std.Io.Reader.fixed(case.bytes);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();

        try testing.expectEqual(case.channels, dec.info.channels);
        try testing.expectEqual(case.sample_rate, dec.info.sample_rate);
        try testing.expectEqual(case.bits, dec.info.bits_per_sample);
        try testing.expectEqual(@as(?u64, case.frames), dec.info.total_frames);

        var out: [4096]i16 = undefined;
        var frames: u64 = 0;
        var saw_signal = false;
        while (true) {
            const n = try dec.read(&out);
            if (n == 0) break;
            frames += n / case.channels;
            for (out[0..n]) |sample| {
                if (sample != 0) saw_signal = true;
            }
        }
        try testing.expectEqual(case.frames, frames);
        try testing.expect(saw_signal);
    }
}

test "committed FLAC fixtures decode to the same PCM as their WAV sources" {
    // Fully offline: the FLAC encoder is lossless, so both decoders must agree
    // byte for byte on 16-bit, 24-bit and 6-channel material.
    for (flac_cases[0..3]) |case| {
        const source = case.wav_source.?;
        const from_flac = try testutil.decodeAll(testing.allocator, case.bytes, 512);
        defer testing.allocator.free(from_flac);
        const from_wav = try testutil.decodeAll(testing.allocator, source, 512);
        defer testing.allocator.free(from_wav);
        try testing.expectEqualSlices(i16, from_wav, from_flac);
    }
}

test "committed 24-bit FLAC matches ffmpeg -f s32le shifted right by 16" {
    // The documented rule for sources wider than 16 bits, checked against
    // ffmpeg's 32-bit output rather than its own 16-bit reduction.
    const result = try compare.compareWithFfmpegS32(testing.allocator, flac_cases[2].bytes);
    std.debug.print(
        "24-bit FLAC: {d} samples, max_diff {d} vs ffmpeg s32 >> 16\n",
        .{ result.samples, result.max_diff },
    );
    try testing.expectEqual(@as(u16, 0), result.max_diff);
}

test "committed LPC FLAC fixture is Unsupported, not mis-decoded" {
    const case = flac_cases[3];
    var reader = std.Io.Reader.fixed(case.bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 8_000), dec.info.sample_rate);

    var out: [64]i16 = undefined;
    try testing.expectError(error.Unsupported, dec.read(&out));
}

test "committed FLAC fixture: 50% cut and mid-frame cut are Truncated" {
    const bytes = flac_cases[0].bytes;
    for ([_]usize{ bytes.len / 2, bytes.len - 1000 }) |cut| {
        const prefix = try compare.decodePrefix(testing.allocator, bytes[0..cut]);
        defer testing.allocator.free(prefix.samples);
        try testing.expectEqual(@as(?root.Error, error.Truncated), prefix.err);
    }
}

test "committed FLAC fixture: one flipped byte inside a frame is Corrupt" {
    const bytes = flac_cases[0].bytes;
    const mutated = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(mutated);

    // The last ~3 KiB of the file is frame payload, so this byte is covered by
    // the frame CRC-16 and is never metadata.
    const cut = mutated.len - 100;
    mutated[cut] ^= 0xFF;

    const prefix = try compare.decodePrefix(testing.allocator, mutated);
    defer testing.allocator.free(prefix.samples);
    try testing.expectEqual(@as(?root.Error, error.Corrupt), prefix.err);
}

test "integer WAV fixtures match ffmpeg -f s16le sample-for-sample" {
    // 8-bit unsigned, 16-bit, 24-bit, 32-bit, and a 5.1 file: all integer PCM,
    // so the conversion is fully defined and must be bit-exact.
    for ([_]usize{ 0, 1, 2, 3, 5 }) |i| {
        try compare.expectExact(testing.allocator, wav_cases[i].bytes);
    }
}

test "float WAV fixture matches ffmpeg -f s16le within 1 LSB" {
    // The source is float, not integer PCM; ffmpeg's float->s16 rounding is
    // not part of the WAV format, so allow one LSB rather than claiming an
    // exactness the format does not define.
    try compare.expectWithin(testing.allocator, wav_cases[4].bytes, 1);
}
