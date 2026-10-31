//! Tests against small, committed ffmpeg-generated fixtures. Unlike the live
//! ffmpeg tests these run on every CI platform and without any external tools.
//!
//! The files are tiny (0.02 s of a 440 Hz sine) and live in src/fixtures/,
//! with the exact generation commands in src/fixtures/README.md.

const std = @import("std");
const root = @import("root.zig");
const compare = @import("compare.zig");
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

const flac_cases = [_]struct { name: []const u8, bytes: []const u8 }{
    .{ .name = "flac s16 stereo", .bytes = @embedFile("fixtures/flac-s16-stereo-44100.flac") },
    .{ .name = "flac s16 mono 8k", .bytes = @embedFile("fixtures/flac-s16-mono-8000.flac") },
    .{ .name = "flac s16 5.1", .bytes = @embedFile("fixtures/flac-s16-6ch-48000.flac") },
    .{ .name = "flac s24 stereo 96k", .bytes = @embedFile("fixtures/flac-s24-stereo-96000.flac") },
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

test "committed ffmpeg FLAC fixtures are recognized; decoder lands next version" {
    for (flac_cases) |case| {
        try testing.expectEqual(root.Format.flac, root.probe(case.bytes[0..12]).?);
        var reader = std.Io.Reader.fixed(case.bytes);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
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
