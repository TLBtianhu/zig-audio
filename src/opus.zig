//! Ogg Opus: the container, both headers, every audio packet's framing, and
//! the stream length. No decoder.
//!
//! Opus is not one codec but two layers (SILK for speech, CELT for the rest)
//! plus a per-packet switch between them, so the honest split is:
//!
//!   1. container and packet structure  <- this file, this version;
//!   2. SILK, CELT and the mode switch  <- later, and not started.
//!
//! `inspect` walks the whole first Opus logical stream once and reports what a
//! player's file list needs: channel count, pre-skip, mapping, packet count,
//! frame counts per packet, configuration histogram, and the length in samples.
//! `open` runs the same walk and then returns `error.Unsupported`, because
//! there is no decoder to hand the caller. It does not fabricate silence.
//!
//! Opus always runs at 48 kHz. Only the encoder's `input_sample_rate` hint
//! suggests otherwise, and RFC 7845 5.1 says that field is "not the sample rate
//! to use for playback", so `Info.sample_rate` is 48_000 for every stream and
//! the hint is kept beside it, unmodified.
//!
//! Length comes from the granule position, which counts samples *including* the
//! pre-skip: RFC 7845 4.3 gives "PCM sample position = granule position -
//! pre-skip". Summing the packets instead overstates the length, because end
//! trimming lets the last granule cut into the final packet.

const std = @import("std");
const types = @import("types.zig");
const ogg = @import("ogg.zig");
const head_mod = @import("opus_head.zig");
const packet_mod = @import("opus_packet.zig");

pub const Error = types.Error;

pub const Head = head_mod.Head;
pub const Tags = head_mod.Tags;
pub const parseHead = head_mod.parse;
pub const parseTags = head_mod.parseTags;
pub const max_channels = head_mod.max_channels;
pub const max_version = head_mod.max_version;

pub const Packet = packet_mod.Packet;
pub const parsePacket = packet_mod.parse;
pub const Config = packet_mod.Config;
pub const configInfo = packet_mod.configInfo;
pub const samplesPerFrame = packet_mod.samplesPerFrame;
pub const max_frames = packet_mod.max_frames;
pub const max_frame_bytes = packet_mod.max_frame_bytes;

/// The one output rate Opus has. See the module comment.
pub const sample_rate: u32 = 48_000;

pub const Info = struct {
    version: u8,
    channels: u8,
    /// Samples to drop from the start of the decoded stream, and the amount
    /// to subtract from every granule position.
    pre_skip: u16,
    /// The encoder's original rate, kept as metadata. Never the playback rate.
    input_sample_rate: u32,
    /// Q7.8 dB. Recorded, not applied: applying it is a decoder's job.
    output_gain: i16,
    mapping_family: u8,
    stream_count: u8,
    coupled_count: u8,
    mapping: [max_channels]u8,
    mapping_len: u8,
    /// User comments in `OpusTags`; their contents are skipped.
    comment_count: u32,

    /// Always 48_000, independent of `input_sample_rate`.
    sample_rate: u32,
    /// Granule position of the last page that completed a packet.
    granule: u64,
    /// `granule - pre_skip`: the stream's length in samples at 48 kHz. This is
    /// what makes `ffprobe`'s `duration_ts` equal to `total_frames + pre_skip`.
    total_frames: u64,

    /// Audio packets, headers excluded.
    packets: u64,
    /// Opus frames across all packets: `packets` times the frames per packet.
    frames: u64,
    /// Sum of `frames * samples_per_frame`. May exceed `total_frames` by up to
    /// one packet's worth when end trimming cuts into the last packet.
    samples: u64,

    stereo_packets: u64,
    padding_packets: u64,
    /// Audio packets per TOC configuration, 0..31.
    configs: [32]u64,
    /// Audio packets per frame count, 1..48 (`frame_counts[0]` stays unused).
    frame_counts: [max_frames + 1]u64,
};

/// Parse the container, both headers and every packet of the first Opus
/// logical stream, and report its structure. Produces no PCM.
pub fn inspect(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    prefix: []const u8,
) Error!Info {
    var demux = try ogg.Demuxer.init(allocator, reader, prefix);
    defer demux.deinit();

    if (demux.streamCodec() != .opus) return error.Unsupported;

    // The identification header is required to be alone on the first page; the
    // demuxer already hands packets over one at a time, so the page layout
    // does not matter here, only the order.
    const head_packet = (try demux.nextPacket()) orelse return error.Truncated;
    const head = try head_mod.parse(head_packet);

    const tags_packet = (try demux.nextPacket()) orelse return error.Truncated;
    const tags = try head_mod.parseTags(tags_packet);

    var info = Info{
        .version = head.version,
        .channels = head.channels,
        .pre_skip = head.pre_skip,
        .input_sample_rate = head.input_sample_rate,
        .output_gain = head.output_gain,
        .mapping_family = head.mapping_family,
        .stream_count = head.stream_count,
        .coupled_count = head.coupled_count,
        .mapping = head.mapping,
        .mapping_len = head.mapping_len,
        .comment_count = tags.comments,
        .sample_rate = sample_rate,
        .granule = 0,
        .total_frames = 0,
        .packets = 0,
        .frames = 0,
        .samples = 0,
        .stereo_packets = 0,
        .padding_packets = 0,
        .configs = @splat(0),
        .frame_counts = @splat(0),
    };

    while (try demux.nextPacket()) |bytes| {
        const packet = try packet_mod.parse(bytes);
        info.packets += 1;
        info.frames += packet.frame_count;
        info.samples += packet.totalSamples();
        if (packet.stereo) info.stereo_packets += 1;
        if (packet.padding != 0) info.padding_packets += 1;
        info.configs[packet.config] += 1;
        info.frame_counts[packet.frame_count] += 1;
    }

    const granule = demux.lastGranule() orelse return error.Truncated;
    // A granule position before the pre-skip means the stream claims to end
    // before it starts; there is no PCM position to report.
    if (granule < head.pre_skip) return error.Corrupt;

    info.granule = granule;
    info.total_frames = granule - head.pre_skip;
    return info;
}

/// Parse the head and the packet structure, then refuse: there is no Opus
/// decoder yet, so this version never returns PCM.
///
/// The parse runs for real, on purpose. A `.opus` file that this function
/// cannot parse has to fail as `Corrupt`/`Truncated` here rather than pretend
/// to be playable later. `Info` owns no memory, so nothing can leak on the way
/// out.
pub fn open(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    prefix: []const u8,
) Error!Info {
    _ = try inspect(allocator, reader, prefix);
    return error.Unsupported;
}
