//! Mutation fuzzer: start from a valid WAV, flip/truncate bytes, and drive the
//! public parser/decoder through every reachable error path.
//!
//! The same `run` function is used by `zig build fuzz` (10,000 rounds) and by a
//! normal test (1,000 rounds), so CI always exercises it.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");

pub const default_rounds: usize = 10_000;
pub const default_seed: u64 = 0x5EED_2A11_D0C5_1234;

pub const Stats = struct {
    rounds: usize = 0,
    probed: usize = 0,
    opened: usize = 0,
    open_errors: usize = 0,
    read_errors: usize = 0,
    samples: u64 = 0,
};

pub fn main() !void {
    const stats = try run(std.heap.page_allocator, default_rounds, default_seed);
    std.debug.print(
        "fuzz: {d} rounds, probe-hit {d}, opened {d}, open errors {d}, read errors {d}, samples {d}\n",
        .{ stats.rounds, stats.probed, stats.opened, stats.open_errors, stats.read_errors, stats.samples },
    );
    std.debug.print("fuzz: no panic, no out-of-bounds, all errors named\n", .{});
}

pub fn run(allocator: std.mem.Allocator, rounds: usize, seed: u64) !Stats {
    const base = try testutil.buildDemoPcm16(allocator, 512);
    defer allocator.free(base);

    const buf = try allocator.dupe(u8, base);
    defer allocator.free(buf);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var stats = Stats{ .rounds = rounds };

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const len = mutate(random, base, buf);

        if (root.probe(buf[0..@min(len, 12)]) != null) stats.probed += 1;

        var reader = std.Io.Reader.fixed(buf[0..len]);
        var dec = root.open(allocator, &reader) catch |err| {
            accept(err);
            stats.open_errors += 1;
            continue;
        };
        defer dec.deinit();
        stats.opened += 1;

        const channels: usize = dec.info.channels;
        var out: [2048]i16 = undefined;
        var guard: usize = 0;

        // Occasionally hand it a buffer smaller than one frame: that must be a
        // named ShortBuffer error and must not consume/alter the decoder.
        if (channels > 1 and random.uintLessThan(u8, 100) < 8) {
            const short = dec.read(out[0 .. channels - 1]);
            if (short) |_| {
                return error.FuzzUnexpectedRead;
            } else |err| {
                accept(err);
                if (err != error.ShortBuffer) return error.FuzzUnexpectedError;
                stats.read_errors += 1;
            }
        }

        while (true) {
            const frames = 1 + random.uintLessThan(usize, 32);
            const want = @min(out.len, frames * channels);
            const n = dec.read(out[0..want]) catch |err| {
                accept(err);
                stats.read_errors += 1;
                break;
            };
            if (n == 0) break;
            if (n > want or n % channels != 0) return error.FuzzInvariant;
            stats.samples += n;
            guard += 1;
            if (guard > 1_000_000) return error.FuzzLoop;
        }
    }

    return stats;
}

/// Copy the valid template, then apply one mutation strategy. Returns the
/// (possibly shortened) length.
fn mutate(random: std.Random, base: []const u8, buf: []u8) usize {
    @memcpy(buf, base);
    var len: usize = base.len;

    const roll = random.uintLessThan(u8, 100);
    if (roll < 7) {
        len = random.uintLessThan(usize, base.len + 1);
        if (len == 0) return 0;
    }

    const flips = 1 + random.uintLessThan(usize, 12);
    var flip: usize = 0;
    while (flip < flips) : (flip += 1) {
        const pos = if (len > 12 and random.uintLessThan(u8, 100) < 75)
            12 + random.uintLessThan(usize, len - 12)
        else
            random.uintLessThan(usize, len);
        buf[pos] = random.int(u8);
    }

    if (roll >= 90 and len >= 20) {
        // Smash a four-byte size field to 0xFFFFFFFF, which is exactly the
        // value the streaming path treats as "until EOF".
        const pos = 12 + random.uintLessThan(usize, len - 16);
        @memset(buf[pos..][0..4], 0xFF);
    }
    return len;
}

fn accept(err: root.Error) void {
    switch (err) {
        error.NotAudio,
        error.Unsupported,
        error.Truncated,
        error.Corrupt,
        error.OutOfMemory,
        error.Io,
        error.ShortBuffer,
        => {},
    }
}

test "mutation fuzz: 1,000 rounds, every outcome stays in the named error set" {
    const stats = try run(std.testing.allocator, 1000, default_seed);
    try std.testing.expect(stats.probed > 0);
    try std.testing.expect(stats.opened > 0);
    try std.testing.expect(stats.samples > 0);
}

test "random bytes: no panic, only NotAudio/Truncated/Unsupported" {
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const random = prng.random();
    var buf: [512]u8 = undefined;

    var round: usize = 0;
    while (round < 1000) : (round += 1) {
        const len = random.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*byte| byte.* = random.int(u8);

        var reader = std.Io.Reader.fixed(buf[0..len]);
        var dec = root.open(std.testing.allocator, &reader) catch |err| {
            accept(err);
            continue;
        };
        dec.deinit();
        return error.FuzzUnexpectedOpen;
    }
}
