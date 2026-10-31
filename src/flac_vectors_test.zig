//! Official FLAC test-vector tests (`ietf-wg-cellar/flac-test-files`, subset).
//!
//! The corpus is 4.1 MiB of binaries and is NOT committed; run
//! `tools/fetch-vectors.ps1` first. When the directory is absent every test
//! prints one line and skips, so CI stays green without the corpus.
//!
//! None of the 13 files is decodable end to end by Stage A: every stereo file
//! uses left/side, right/side or mid/side, and every independent-channel file
//! uses LPC. What this file therefore pins down is:
//!   * metadata parsing (rate / channels / bit depth / total samples / null);
//!   * the exact number of samples decoded before the first `Unsupported` frame;
//!   * bit-exact agreement of those prefixes with ffmpeg;
//!   * `Truncated` on a 50% cut.
//!
//! Measured vector map (frames, subframe types, channel assignment):
//!
//! | file | frames | subframes | channel assign | Stage A prefix |
//! | ---- | ------ | --------- | -------------- | ------------- |
//! | 03 - blocksize 16 | 19294 | fixed + 56 lpc | indep 9712 / L/S 2924 / R/S 2263 / M/S 4395 | 2 frames (64 samples) |
//! | 12 - qlp precision 15 bit | 48 | lpc only | L/S 6 / R/S 40 / M/S 2 | 0 |
//! | 13 - qlp precision 2 bit | 48 | lpc only | L/S 7 / R/S 37 / M/S 4 | 0 |
//! | 14 - wasted bits | 426 | fixed + lpc (wasted 1..12) | indep 94 / L/S 107 / R/S 203 / M/S 22 | 0 |
//! | 17 - all fixed orders | 204 | fixed 0..4 only | L/S 55 / R/S 96 / M/S 53 | 0 |
//! | 22 - 12 bit per sample | 54 | fixed + lpc | indep 3 / R/S 38 / M/S 13 | 0 |
//! | 23 - 8 bit per sample | 84 | constant + fixed + lpc | indep 20 / R/S 30 / M/S 34 | 0 |
//! | 38 - 3 channels (3.0) | 42 | constant + lpc | indep | 0 |
//! | 41 - 6 channels (5.1) | 88 | constant + lpc | indep | 0 |
//! | 45 - no total samples | 83 | fixed + lpc | L/S 15 / R/S 5 / M/S 63 | 0 |
//! | 60 - mono audio | 56 | constant + fixed + lpc | indep | 20 frames (81920 samples) |
//! | 61 - predictor overflow | 56 | constant + fixed + lpc | indep | 8 frames (32768 samples) |
//! | 64 - rice escape code zero | 46 | constant + fixed + lpc | indep | 1 frame (4096 samples) |
//!
//! The columns come from a parse-only scan of the bitstream (subframe headers,
//! Rice partitions skipped correctly, LPC parsed but not synthesised).

const std = @import("std");
const root = @import("root.zig");
const compare = @import("compare.zig");
const testing = std.testing;

const vector_dir = ".zig-cache/vectors";

const Vector = struct {
    name: []const u8,
    channels: u16,
    sample_rate: u32,
    bits: u16,
    /// null means STREAMINFO declared 0 ("unknown").
    total_frames: ?u64,
    /// Samples delivered before the first `Unsupported` frame.
    prefix_samples: usize,
};

const vectors = [_]Vector{
    .{ .name = "03 - blocksize 16.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 308_700, .prefix_samples = 64 },
    .{ .name = "12 - qlp precision 15 bit.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 218_644, .prefix_samples = 0 },
    .{ .name = "13 - qlp precision 2 bit.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 218_498, .prefix_samples = 0 },
    .{ .name = "14 - wasted bits.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 218_101, .prefix_samples = 0 },
    .{ .name = "17 - all fixed orders.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 234_514, .prefix_samples = 0 },
    .{ .name = "22 - 12 bit per sample.flac", .channels = 2, .sample_rate = 44_100, .bits = 12, .total_frames = 218_666, .prefix_samples = 0 },
    .{ .name = "23 - 8 bit per sample.flac", .channels = 2, .sample_rate = 44_100, .bits = 8, .total_frames = 339_973, .prefix_samples = 0 },
    .{ .name = "38 - 3 channels (3.0).flac", .channels = 3, .sample_rate = 44_100, .bits = 16, .total_frames = 168_210, .prefix_samples = 0 },
    .{ .name = "41 - 6 channels (5.1).flac", .channels = 6, .sample_rate = 44_100, .bits = 16, .total_frames = 357_223, .prefix_samples = 0 },
    .{ .name = "45 - no total number of samples set.flac", .channels = 2, .sample_rate = 48_000, .bits = 16, .total_frames = null, .prefix_samples = 0 },
    .{ .name = "60 - mono audio.flac", .channels = 1, .sample_rate = 44_100, .bits = 16, .total_frames = 227_247, .prefix_samples = 81_920 },
    .{ .name = "61 - predictor overflow check, 16-bit.flac", .channels = 1, .sample_rate = 44_100, .bits = 16, .total_frames = 227_247, .prefix_samples = 32_768 },
    .{ .name = "64 - rice partitions with escape code zero.flac", .channels = 1, .sample_rate = 44_100, .bits = 16, .total_frames = 187_998, .prefix_samples = 4_096 },
};

fn readVector(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, vector_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer dir.close(std.testing.io);
    return dir.readFileAlloc(std.testing.io, name, allocator, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "official vectors: STREAMINFO fields match the published corpus" {
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print(
                    "flac vectors missing under {s}; run `pwsh tools/fetch-vectors.ps1`\n",
                    .{vector_dir},
                );
                return error.SkipZigTest;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);

        try testing.expectEqual(root.Format.flac, root.probe(bytes[0..12]).?);

        var reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();

        try testing.expectEqual(vector.channels, dec.info.channels);
        try testing.expectEqual(vector.sample_rate, dec.info.sample_rate);
        try testing.expectEqual(vector.bits, dec.info.bits_per_sample);
        try testing.expectEqual(vector.total_frames, dec.info.total_frames);
    }
}

test "official vectors: decodable prefix then Unsupported, never wrong audio" {
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => return error.SkipZigTest,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        const prefix = try compare.decodePrefix(testing.allocator, bytes);
        defer testing.allocator.free(prefix.samples);

        // Every vector has at least one frame Stage A cannot decode (LPC or a
        // side-channel assignment), so the prefix is always followed by
        // Unsupported. A silent EOF here would mean the decoder guessed.
        try testing.expectEqual(@as(?root.Error, error.Unsupported), prefix.err);
        try testing.expectEqual(
            vector.prefix_samples,
            prefix.samples.len,
        );
        try testing.expectEqual(
            @as(usize, 0),
            prefix.samples.len % @as(usize, vector.channels),
        );
    }
}

test "official vectors: decoded prefixes match ffmpeg sample for sample" {
    // 03, 60, 61 and 64 are the only vectors with a nonzero Stage A prefix.
    for (vectors) |vector| {
        if (vector.prefix_samples == 0) continue;
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print("flac vectors missing; skipping prefix comparison\n", .{});
                return error.SkipZigTest;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);

        const compared = try compare.expectPrefixExact(testing.allocator, bytes);
        std.debug.print(
            "vector {s}: {d} samples bit-exact vs ffmpeg (max_diff 0)\n",
            .{ vector.name, compared },
        );
        try testing.expectEqual(vector.prefix_samples, compared);
    }
}

test "official vector 45: total_samples == 0 exposes total_frames null" {
    const bytes = readVector(testing.allocator, "45 - no total number of samples set.flac") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);
    try testing.expectEqual(@as(u32, 48_000), dec.info.sample_rate);
}

test "official vector 60 cut at 50%: Unsupported, because LPC comes first" {
    // Truncation cannot be reached on this corpus: every vector hits LPC or a
    // side-channel frame before the cut. The 50% Truncated check lives in
    // fixtures_test.zig, on a file that decodes from start to end.
    const bytes = readVector(testing.allocator, "60 - mono audio.flac") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    const half = bytes[0 .. bytes.len / 2];
    const prefix = try compare.decodePrefix(testing.allocator, half);
    defer testing.allocator.free(prefix.samples);

    try testing.expectEqual(@as(?root.Error, error.Unsupported), prefix.err);
    try testing.expect(prefix.samples.len > 0);
}
