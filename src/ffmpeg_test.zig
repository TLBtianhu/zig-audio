//! Integration tests against a real ffmpeg binary, when one is available.
//!
//! ffmpeg writes WAV to a pipe with `data` size 0xFFFFFFFF, so these tests also
//! cover the "unknown length, decode until EOF" path on real encoder output.
//! The FLAC cases are encoded with `-lpc_type none -ch_mode indep`, i.e. the
//! Stage A subset, and compared sample for sample with ffmpeg's decoder.
//! On non-Windows runners (or when the binary is absent) every test skips; CI
//! does not depend on ffmpeg.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const compare = @import("compare.zig");
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

/// Encode FLAC with the encoder's LPC stage disabled, i.e. the Stage A subset
/// (fixed predictors, independent channels).
fn generateFlac(
    allocator: std.mem.Allocator,
    channels_arg: []const u8,
    duration: []const u8,
    bits: u16,
) ![]u8 {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const filter = try std.fmt.allocPrint(
        allocator,
        "sine=frequency=440:duration={s}",
        .{duration},
    );
    defer allocator.free(filter);

    var argv: [32][]const u8 = undefined;
    var len: usize = 0;
    const fixed_args = [_][]const u8{
        ffmpeg_path, "-v",    "error",                "-f",         "lavfi",
        "-i",        filter,  "-ac",                  channels_arg, "-ar",
        "44100",     "-c:a",  "flac",                 "-lpc_type",  "none",
        "-ch_mode",  "indep", "-max_partition_order", "4",
    };
    for (fixed_args) |arg| {
        argv[len] = arg;
        len += 1;
    }
    if (bits == 24) {
        for ([_][]const u8{ "-sample_fmt", "s32", "-bits_per_raw_sample", "24" }) |arg| {
            argv[len] = arg;
            len += 1;
        }
    }
    for ([_][]const u8{ "-f", "flac", "pipe:1" }) |arg| {
        argv[len] = arg;
        len += 1;
    }

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = argv[0..len],
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("ffmpeg flac failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.FfmpegFailed;
    }
    return result.stdout;
}

test "ffmpeg: FLAC fixed-predictor 16-bit stereo matches sample for sample" {
    const bytes = try generateFlac(testing.allocator, "2", "0.2", 16);
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 2), dec.info.channels);
    try testing.expectEqual(@as(u16, 16), dec.info.bits_per_sample);
    // ffmpeg writes to a pipe, so it cannot know the total sample count.\r`n    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);

    try compare.expectExact(testing.allocator, bytes);
}

test "ffmpeg: FLAC fixed-predictor 24-bit stereo matches s32 >> 16" {
    const bytes = try generateFlac(testing.allocator, "2", "0.2", 24);
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 24), dec.info.bits_per_sample);

    try compare.expectExactS32(testing.allocator, bytes);
}

test "ffmpeg: FLAC fixed-predictor 5.1 matches sample for sample" {
    const bytes = try generateFlac(testing.allocator, "6", "0.1", 16);
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 6), dec.info.channels);

    try compare.expectExact(testing.allocator, bytes);
}

test "ffmpeg: LPC FLAC is Unsupported on the first frame" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const filter = "sine=frequency=440:duration=0.1";
    const result = std.process.run(testing.allocator, std.testing.io, .{
        .argv = &.{
            ffmpeg_path, "-v",        "error",    "-f",
            "lavfi",     "-i",        filter,     "-ac",
            "2",         "-ar",       "44100",    "-c:a",
            "flac",      "-lpc_type", "levinson", "-f",
            "flac",      "pipe:1",
        },
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.FfmpegFailed;

    var reader = std.Io.Reader.fixed(result.stdout);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    var out: [256]i16 = undefined;
    try testing.expectError(error.Unsupported, dec.read(&out));
}
