//! Test helper: compare this decoder's i16 output against ffmpeg's `-f s16le`
//! reference, sample by sample (bytes are little-endian, exactly what
//! `-f s16le` writes).
//!
//! This is the mechanism the FLAC round will use to prove bit-exact decoding:
//! decode the same file with both implementations and require max_diff == 0.
//! For float WAV input a tolerance of 1 LSB may be used, because the source is
//! not integer PCM and ffmpeg's float->s16 rounding is not part of the format.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const testutil = @import("testutil.zig");

pub const ffmpeg_path = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";

pub const Result = struct {
    samples: usize,
    max_diff: u16,
    first_mismatch: ?usize = null,
    first_ours: i16 = 0,
    first_ref: i16 = 0,
};

/// Decode `bytes` with zig-audio and with ffmpeg, and return the largest
/// absolute difference between corresponding i16 samples.
pub fn compareWithFfmpeg(allocator: std.mem.Allocator, bytes: []const u8) !Result {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const ours = try testutil.decodeAll(allocator, bytes, 512);
    defer allocator.free(ours);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.bin", .data = bytes });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const input_path = try std.fmt.allocPrint(
        allocator,
        "{s}{s}input.bin",
        .{ path_buffer[0..dir_len], std.fs.path.sep_str },
    );
    defer allocator.free(input_path);

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{
            ffmpeg_path, "-v",       "error",
            "-i",        input_path, "-f",
            "s16le",     "-c:a",     "pcm_s16le",
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
        std.debug.print("ffmpeg reference decode failed: {s}\n", .{result.stderr});
        return error.FfmpegFailed;
    }
    if (result.stdout.len % 2 != 0) return error.OddReferenceLength;

    const reference_samples = result.stdout.len / 2;
    if (reference_samples != ours.len) {
        std.debug.print(
            "sample count mismatch: zig-audio {d}, ffmpeg {d}\n",
            .{ ours.len, reference_samples },
        );
        return error.SampleCountMismatch;
    }

    var max_diff: u16 = 0;
    var first_mismatch: ?usize = null;
    var first_ours: i16 = 0;
    var first_ref: i16 = 0;
    for (ours, 0..) |ours_sample, i| {
        const ref_sample = std.mem.readInt(i16, result.stdout[i * 2 ..][0..2], .little);
        const diff: i32 = @as(i32, ours_sample) - @as(i32, ref_sample);
        const abs_diff: u16 = @intCast(if (diff < 0) -diff else diff);
        if (abs_diff != 0 and first_mismatch == null) {
            first_mismatch = i;
            first_ours = ours_sample;
            first_ref = ref_sample;
        }
        if (abs_diff > max_diff) max_diff = abs_diff;
    }

    return .{
        .samples = ours.len,
        .max_diff = max_diff,
        .first_mismatch = first_mismatch,
        .first_ours = first_ours,
        .first_ref = first_ref,
    };
}

/// Require bit-exact agreement. Prints the failing sample and both values.
pub fn expectExact(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const result = try compareWithFfmpeg(allocator, bytes);
    if (result.max_diff != 0) {
        std.debug.print(
            "PCM mismatch: {d} samples, max diff {d}, first at {d}: ours {d}, ffmpeg {d}\n",
            .{
                result.samples,
                result.max_diff,
                result.first_mismatch.?,
                result.first_ours,
                result.first_ref,
            },
        );
        return error.PcmMismatch;
    }
}

/// Require agreement within `tolerance` LSBs (use 0 for integer PCM).
pub fn expectWithin(allocator: std.mem.Allocator, bytes: []const u8, tolerance: u16) !void {
    const result = try compareWithFfmpeg(allocator, bytes);
    if (result.max_diff > tolerance) {
        std.debug.print(
            "PCM mismatch: {d} samples, max diff {d} > tolerance {d}, first at {d}: ours {d}, ffmpeg {d}\n",
            .{
                result.samples,
                result.max_diff,
                tolerance,
                result.first_mismatch.?,
                result.first_ours,
                result.first_ref,
            },
        );
        return error.PcmMismatch;
    }
}
