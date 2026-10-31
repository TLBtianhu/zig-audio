//! Decode benchmark: 10 seconds of 16-bit stereo 44.1 kHz WAV, built in memory
//! and decoded through the public streaming API.
//!
//! The benchmark always compiles as ReleaseFast (see build.zig). It fails if
//! throughput drops below 200x realtime, so a regression is visible instead of
//! being a number nobody reads.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");

const sample_rate: u32 = 44_100;
const channels: u16 = 2;
const seconds: u32 = 10;
const target_speedup: f64 = 200.0;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const total_frames: usize = sample_rate * seconds;

    const wav = try testutil.buildDemoPcm16(allocator, total_frames);
    defer allocator.free(wav);

    var reader = std.Io.Reader.fixed(wav);
    var dec = try root.open(allocator, &reader);
    defer dec.deinit();

    if (dec.info.total_frames != total_frames) return error.UnexpectedFrameCount;

    const io = std.Io.Threaded.global_single_threaded.io();
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (true) {
        const n = try dec.read(&pcm);
        if (n == 0) break;
        if (n % channels != 0) return error.UnexpectedSampleCount;
        decoded_frames += n / channels;
        // Consume every sample so the optimizer cannot drop the stores; a
        // benchmark that only counts bytes is not measuring real output.
        for (pcm[0..n]) |sample| checksum +%= sample;
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);

    if (decoded_frames != total_frames) return error.UnexpectedFrameCount;
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;

    const elapsed_s = elapsed_ns / std.time.ns_per_s;
    const audio_s: f64 = @as(f64, @floatFromInt(decoded_frames)) / @as(f64, @floatFromInt(sample_rate));
    const pcm_bytes: f64 = @floatFromInt(decoded_frames * channels * 2);
    const mb_per_s = pcm_bytes / (1024.0 * 1024.0) / elapsed_s;
    const speedup = audio_s / elapsed_s;

    std.debug.print(
        "zig-audio bench: WAV PCM16 {d} Hz, {d} ch, {d:.1} s ({d} frames)\n",
        .{ sample_rate, channels, audio_s, decoded_frames },
    );
    std.debug.print(
        "decoded in {d:.3} ms  =>  {d:.1} MiB/s (PCM out), {d:.0}x realtime\n",
        .{ elapsed_ns / std.time.ns_per_ms, mb_per_s, speedup },
    );

    if (speedup < target_speedup) {
        std.debug.print(
            "FAIL: {d:.1}x realtime is below the {d:.0}x target\n",
            .{ speedup, target_speedup },
        );
        return error.BelowThroughputTarget;
    }
    std.debug.print("OK: above the {d:.0}x realtime target\n", .{target_speedup});
}
