//! FLAC round scaffolding: check the official test-vector corpus when it is
//! present. The vectors are 4.1 MiB of binaries and are NOT committed; run
//! `tools/fetch-vectors.ps1` first. When the directory is absent every test
//! here prints one line and skips, so CI stays green without the corpus.
//!
//! The FLAC decoder itself lands next round. Today this validates that every
//! vector is recognized as FLAC and that `open` says Unsupported explicitly.

const std = @import("std");
const root = @import("root.zig");
const testing = std.testing;

const vector_dir = ".zig-cache/vectors";

const vector_names = [_][]const u8{
    "03 - blocksize 16.flac",
    "12 - qlp precision 15 bit.flac",
    "13 - qlp precision 2 bit.flac",
    "14 - wasted bits.flac",
    "17 - all fixed orders.flac",
    "22 - 12 bit per sample.flac",
    "23 - 8 bit per sample.flac",
    "38 - 3 channels (3.0).flac",
    "41 - 6 channels (5.1).flac",
    "45 - no total number of samples set.flac",
    "60 - mono audio.flac",
    "61 - predictor overflow check, 16-bit.flac",
    "64 - rice partitions with escape code zero.flac",
};

fn skipMissing() error{SkipZigTest} {
    std.debug.print(
        "flac vectors missing under {s}; run `pwsh tools/fetch-vectors.ps1` to enable this test\n",
        .{vector_dir},
    );
    return error.SkipZigTest;
}

test "official FLAC vectors: recognized, decoder explicitly not implemented yet" {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, vector_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return skipMissing(),
        else => return err,
    };
    defer dir.close(std.testing.io);

    for (vector_names) |name| {
        const bytes = dir.readFileAlloc(
            std.testing.io,
            name,
            testing.allocator,
            .limited(8 << 20),
        ) catch |err| switch (err) {
            error.FileNotFound => return skipMissing(),
            else => return err,
        };
        defer testing.allocator.free(bytes);

        try testing.expectEqual(root.Format.flac, root.probe(bytes[0..@min(bytes.len, 12)]).?);

        var reader = std.Io.Reader.fixed(bytes);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
}
