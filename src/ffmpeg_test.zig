//! Integration tests against a real ffmpeg binary, when one is available.
//!
//! ffmpeg writes WAV to a pipe with `data` size 0xFFFFFFFF, so these tests also
//! cover the "unknown length, decode until EOF" path on real encoder output.
//! On non-Windows runners (or when the binary is absent) every test skips; CI
//! does not depend on ffmpeg.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const testing = std.testing;

const ffmpeg_path = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";

fn generate(
    allocator: std.mem.Allocator,
    codec: []const u8,
    channels_arg: []const u8,
    duration: []const u8,
) ![]u8 {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const filter = try std.fmt.allocPrint(
        allocator,
        "sine=frequency=440:duration={s}",
        .{duration},
    );
    defer allocator.free(filter);

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{
            ffmpeg_path, "-v",    "error",
            "-f",        "lavfi", "-i",
            filter,      "-ac",   channels_arg,
            "-ar",       "44100", "-c:a",
            codec,       "-f",    "wav",
            "pipe:1",
        },
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.term.success()) {
        std.debug.print("ffmpeg failed for {s}: {s}\n", .{ codec, result.stderr });
        return error.FfmpegFailed;
    }
    return allocator.dupe(u8, result.stdout);
}

fn expectGenerated(
    bytes: []const u8,
    expected_channels: u16,
    expected_bits: u16,
    expected_frames: u64,
) !void {
    try testing.expectEqual(root.Format.wav, root.probe(bytes).?);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();

    try testing.expectEqual(expected_channels, dec.info.channels);
    try testing.expectEqual(expected_bits, dec.info.bits_per_sample);
    try testing.expectEqual(@as(u32, 44_100), dec.info.sample_rate);
    // ffmpeg's pipe output has data size 0xFFFFFFFF.
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);

    var out: [4096]i16 = undefined;
    var frames: u64 = 0;
    var saw_signal = false;
    const channels: usize = expected_channels;
    while (true) {
        const n = try dec.read(&out);
        if (n == 0) break;
        try testing.expectEqual(@as(usize, 0), n % channels);
        frames += n / channels;
        for (out[0..n]) |sample| {
            if (sample != 0) saw_signal = true;
        }
    }

    try testing.expectEqual(expected_frames, frames);
    try testing.expect(saw_signal);
}

test "ffmpeg: PCM16 stereo" {
    const bytes = try generate(testing.allocator, "pcm_s16le", "2", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 2, 16, 4410);
}

test "ffmpeg: unsigned PCM8 mono" {
    const bytes = try generate(testing.allocator, "pcm_u8", "1", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 1, 8, 4410);
}

test "ffmpeg: PCM24 stereo" {
    const bytes = try generate(testing.allocator, "pcm_s24le", "2", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 2, 24, 4410);
}

test "ffmpeg: PCM32 stereo" {
    const bytes = try generate(testing.allocator, "pcm_s32le", "2", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 2, 32, 4410);
}

test "ffmpeg: float32 stereo" {
    const bytes = try generate(testing.allocator, "pcm_f32le", "2", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 2, 32, 4410);
}

test "ffmpeg: 5.1 PCM24 through WAVE_FORMAT_EXTENSIBLE" {
    const bytes = try generate(testing.allocator, "pcm_s24le", "6", "0.1");
    defer testing.allocator.free(bytes);
    try expectGenerated(bytes, 6, 24, 4410);
}
