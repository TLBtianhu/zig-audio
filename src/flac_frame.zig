//! FLAC frame decoding: header, CrC-8, subframes, Rice residual, CRC-16.
//!
//! Supported subset:
//!   * subframes: CONSTANT, VERBATIM, FIXED orders 0..4, all Rice partitions
//!     (including the escape code), wasted bits;
//!   * channel assignment: independent (0..7), left/side (8), right/side (9)
//!     and mid/side (10).
//!
//! LPC subframes are recognized and answered with `error.Unsupported`, never
//! mis-decoded: a decoder that emits wrong PCM is worse than one that says
//! "not yet".

const std = @import("std");
const types = @import("types.zig");
const bits_mod = @import("flac_bits.zig");
const meta = @import("flac_meta.zig");

pub const Error = types.Error;
const BitReader = bits_mod.BitReader;

/// A long run of zero bits is legal in principle but never appears in real
/// residuals; bounding it keeps a corrupt stream from spinning.
const max_unary: u32 = 1 << 24;

pub const Header = struct {
    variable_blocking: bool,
    block_size: u32,
    /// 0 means "take STREAMINFO's value".
    sample_rate: u32,
    /// 0..7 independent (n+1 channels), 8..10 decorrelated, 11..15 reserved.
    channel_assignment: u4,
    /// 0 means "take STREAMINFO's value".
    bits_per_sample: u8,
    /// CRC-16 of the header bytes: the frame CRC starts here.
    crc16_seed: u16,

    pub fn isIndependent(self: Header) bool {
        return self.channel_assignment <= 7;
    }

    pub fn channels(self: Header) u8 {
        if (self.channel_assignment <= 7) return self.channel_assignment + 1;
        return 2;
    }
};

/// Parse one frame header. The reader must be positioned at the sync code and
/// the header ends exactly on a byte boundary.
pub fn readHeader(reader: *std.Io.Reader) Error!Header {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    for (0..4) |_| {
        buf[len] = try takeByte(reader);
        len += 1;
    }
    // 14-bit sync, reserved bit 0, then the blocking strategy.
    if (buf[0] != 0xFF or (buf[1] & 0xFE) != 0xF8) return error.Corrupt;
    if (buf[3] & 0x01 != 0) return error.Corrupt; // reserved

    const variable = buf[1] & 0x01 != 0;
    const block_code = buf[2] >> 4;
    const rate_code = buf[2] & 0x0F;
    const assignment: u4 = @intCast(buf[3] >> 4);
    const size_code: u3 = @intCast((buf[3] >> 1) & 0x07);

    len = try readCodedNumber(reader, &buf, len, variable);

    var block_size: u32 = 0;
    switch (block_code) {
        0 => return error.Corrupt, // reserved
        1 => block_size = 192,
        2...5 => block_size = @as(u32, 576) << @intCast(block_code - 2),
        6 => {
            buf[len] = try takeByte(reader);
            len += 1;
            block_size = @as(u32, buf[len - 1]) + 1;
        },
        7 => {
            buf[len] = try takeByte(reader);
            buf[len + 1] = try takeByte(reader);
            len += 2;
            block_size = std.mem.readInt(u16, buf[len - 2 ..][0..2], .big) + 1;
        },
        else => block_size = @as(u32, 256) << @intCast(block_code - 8),
    }

    var sample_rate: u32 = 0;
    switch (rate_code) {
        0 => {},
        1 => sample_rate = 88_200,
        2 => sample_rate = 176_400,
        3 => sample_rate = 192_000,
        4 => sample_rate = 8_000,
        5 => sample_rate = 16_000,
        6 => sample_rate = 22_050,
        7 => sample_rate = 24_000,
        8 => sample_rate = 32_000,
        9 => sample_rate = 44_100,
        10 => sample_rate = 48_000,
        11 => sample_rate = 96_000,
        12 => {
            buf[len] = try takeByte(reader);
            len += 1;
            sample_rate = @as(u32, buf[len - 1]) * 1000;
        },
        13 => {
            buf[len] = try takeByte(reader);
            buf[len + 1] = try takeByte(reader);
            len += 2;
            sample_rate = std.mem.readInt(u16, buf[len - 2 ..][0..2], .big);
        },
        14 => {
            buf[len] = try takeByte(reader);
            buf[len + 1] = try takeByte(reader);
            len += 2;
            sample_rate = @as(u32, std.mem.readInt(u16, buf[len - 2 ..][0..2], .big)) * 10;
        },
        else => return error.Corrupt, // 15: invalid
    }

    const header_crc = try takeByte(reader);
    if (bits_mod.crc8(buf[0..len]) != header_crc) return error.Corrupt;

    var seed: u16 = 0;
    for (buf[0..len]) |byte| seed = bits_mod.crc16Update(seed, byte);
    seed = bits_mod.crc16Update(seed, header_crc);

    const bits_per_sample: u8 = switch (size_code) {
        0 => 0,
        1 => 8,
        2 => 12,
        3 => return error.Corrupt, // reserved
        4 => 16,
        5 => 20,
        6 => 24,
        7 => 32,
    };
    if (assignment > 10) return error.Corrupt;

    return .{
        .variable_blocking = variable,
        .block_size = block_size,
        .sample_rate = sample_rate,
        .channel_assignment = assignment,
        .bits_per_sample = bits_per_sample,
        .crc16_seed = seed,
    };
}

/// UTF-8 style coded number: frame number for fixed-blocking streams (up to 6
/// bytes), sample number for variable-blocking ones (up to 7).
fn readCodedNumber(
    reader: *std.Io.Reader,
    buf: *[16]u8,
    start: usize,
    variable: bool,
) Error!usize {
    var len = start;
    buf[len] = try takeByte(reader);
    const first = buf[len];
    len += 1;
    if (first < 0x80) return len;

    var ones: u8 = 0;
    var mask: u8 = 0x80;
    while (first & mask != 0) {
        ones += 1;
        mask >>= 1;
    }
    if (ones < 2) return error.Corrupt; // a continuation byte cannot start
    if (ones > 7) return error.Corrupt;
    if (!variable and ones > 6) return error.Corrupt;

    var i: u8 = 0;
    while (i < ones - 1) : (i += 1) {
        const cont = try takeByte(reader);
        if (cont & 0xC0 != 0x80) return error.Corrupt;
        buf[len] = cont;
        len += 1;
    }
    return len;
}

/// Decode one frame body into planar i32 samples:
/// `out[channel * block_size + sample]`.
///
/// The subframe loop is shared by independent and decorrelated frames: a side
/// subframe is simply the one whose bit depth is one higher. Reconstruction
/// runs after both subframes have been decoded, which is also after
/// `decodeSubframe` has restored their wasted bits.
pub fn decode(
    reader: *std.Io.Reader,
    header: Header,
    stream: *const meta.StreamInfo,
    out: []i32,
) Error!void {
    if (header.channels() != stream.channels) return error.Corrupt;
    if (header.bits_per_sample != 0 and header.bits_per_sample != stream.bits_per_sample) {
        return error.Corrupt;
    }
    if (header.sample_rate != 0 and header.sample_rate != stream.sample_rate) {
        return error.Corrupt;
    }

    const block_size: usize = header.block_size;
    const channels: usize = stream.channels;
    if (out.len != block_size * channels) return error.Corrupt;
    const bps = stream.bits_per_sample;
    const decorrelated = !header.isIndependent();
    // A side channel is one bit wider than the source. At 32 bps that would be
    // 33 bits, which neither the i32 frame buffer nor the 32-bit bit reader can
    // hold; say so instead of truncating the top bit.
    if (decorrelated and bps >= 32) return error.Unsupported;
    // right/side stores its side subframe first; the other two store it second.
    const side_first = decorrelated and header.channel_assignment == 9;
    const subframes: usize = if (decorrelated) 2 else channels;

    var bits = BitReader.init(reader, header.crc16_seed);
    for (0..subframes) |channel| {
        const sub_bps = if (decorrelated and (side_first == (channel == 0))) bps + 1 else bps;
        const plane = out[channel * block_size ..][0..block_size];
        try decodeSubframe(&bits, header.block_size, sub_bps, plane);
    }
    bits.alignToByte();
    const expected = try bits.readFrameCrc16();
    if (bits.crc16 != expected) return error.Corrupt;

    if (decorrelated) {
        try reconstruct(header.channel_assignment, out[0..block_size], out[block_size..][0..block_size]);
    }
}

/// Undo left/side (8), right/side (9) or mid/side (10). The side plane is
/// `second` for 8 and 10 and `first` for 9; both planes already hold the
/// restored (wasted-bits-expanded) samples.
fn reconstruct(assignment: u4, first: []i32, second: []i32) Error!void {
    switch (assignment) {
        8 => {
            // side = left - right, so right = left - side.
            for (first, second) |l, *r| r.* = try fit(@as(i64, l) - @as(i64, r.*));
        },
        9 => {
            // side = left - right, so left = right + side.
            for (first, second) |*s, r| s.* = try fit(@as(i64, r) + @as(i64, s.*));
        },
        10 => {
            for (first, second) |*m, *s| {
                // Restore the sum's low bit from the side channel; without
                // `(side & 1)` the output is off by one sample value and the
                // frame CRC still matches.
                const side: i64 = s.*;
                const twice: i64 = (@as(i64, m.*) << 1) | (side & 1);
                m.* = try fit((twice + side) >> 1);
                s.* = try fit((twice - side) >> 1);
            }
        },
        else => return error.Corrupt, // 11..15 are rejected by readHeader
    }
}

fn decodeSubframe(
    bits: *BitReader,
    block_size: u32,
    bps: u16,
    out: []i32,
) Error!void {
    if (try bits.readBit() != 0) return error.Corrupt;
    const sub_type = try bits.readBits(6);

    var wasted: u5 = 0;
    if (try bits.readBit() != 0) {
        const count = try bits.readUnary(31);
        if (count >= 31) return error.Corrupt;
        wasted = @intCast(count + 1);
        if (wasted >= bps) return error.Corrupt;
    }
    const effective: u6 = @intCast(bps - wasted);

    switch (sub_type) {
        0 => {
            const value = try bits.readSigned(effective);
            @memset(out, value);
        },
        1 => {
            for (out) |*slot| slot.* = try bits.readSigned(effective);
        },
        8...15 => {
            const order: u8 = @intCast(sub_type & 0x07);
            if (order > 4) return error.Corrupt;
            try decodeFixed(bits, block_size, effective, order, out);
        },
        // LPC: deliberately not implemented yet. Answering Unsupported
        // before consuming the subframe is what keeps the error honest.
        32...63 => return error.Unsupported,
        else => return error.Corrupt, // reserved subframe types
    }

    if (wasted > 0) {
        const shift: u5 = wasted;
        for (out) |*slot| {
            slot.* = @intCast(@as(i64, slot.*) << shift);
        }
    }
}

fn decodeFixed(
    bits: *BitReader,
    block_size: u32,
    bps: u6,
    order: u8,
    out: []i32,
) Error!void {
    var i: usize = 0;
    while (i < order) : (i += 1) out[i] = try bits.readSigned(bps);
    try decodeResidual(bits, out[order..], order, block_size);

    const n = out.len;
    switch (order) {
        0 => {},
        1 => {
            var j: usize = 1;
            while (j < n) : (j += 1) out[j] = try fit(@as(i64, out[j]) + out[j - 1]);
        },
        2 => {
            var j: usize = 2;
            while (j < n) : (j += 1) {
                out[j] = try fit(@as(i64, out[j]) + 2 * @as(i64, out[j - 1]) - out[j - 2]);
            }
        },
        3 => {
            var j: usize = 3;
            while (j < n) : (j += 1) {
                out[j] = try fit(@as(i64, out[j]) + 3 * @as(i64, out[j - 1]) -
                    3 * @as(i64, out[j - 2]) + out[j - 3]);
            }
        },
        4 => {
            var j: usize = 4;
            while (j < n) : (j += 1) {
                out[j] = try fit(@as(i64, out[j]) + 4 * @as(i64, out[j - 1]) -
                    6 * @as(i64, out[j - 2]) + 4 * @as(i64, out[j - 3]) - out[j - 4]);
            }
        },
        else => return error.Corrupt,
    }
}

fn decodeResidual(
    bits: *BitReader,
    dest: []i32,
    order: u8,
    block_size: u32,
) Error!void {
    const method = try bits.readBits(2);
    if (method > 1) return error.Corrupt;
    const param_bits: u6 = if (method == 0) 4 else 5;
    const escape: u32 = (@as(u32, 1) << @intCast(param_bits)) - 1;

    const partition_order = try bits.readBits(4);
    const partitions: u32 = @as(u32, 1) << @intCast(partition_order);
    if (block_size % partitions != 0) return error.Corrupt;
    const per = block_size / partitions;
    if (per < order) return error.Corrupt;

    var index: usize = 0;
    var p: u32 = 0;
    while (p < partitions) : (p += 1) {
        const count: usize = if (p == 0) per - order else per;
        const param = try bits.readBits(param_bits);
        if (param == escape) {
            const raw_bits = try bits.readBits(5);
            const slice = dest[index..][0..count];
            if (raw_bits == 0) {
                @memset(slice, 0);
            } else {
                for (slice) |*slot| slot.* = try bits.readSigned(@intCast(raw_bits));
            }
        } else {
            const shift: u5 = @intCast(param);
            for (dest[index..][0..count]) |*slot| {
                const quotient = try bits.readUnary(max_unary);
                const remainder = try bits.readBits(@intCast(param));
                const folded: u64 = (@as(u64, quotient) << shift) | remainder;
                // Rice maps signed residuals to unsigned by folding: the low
                // bit is the sign, the rest is magnitude-1.
                const magnitude: i64 = @intCast(folded >> 1);
                const value: i64 = magnitude ^ -@as(i64, @intCast(folded & 1));
                slot.* = try fit(value);
            }
        }
        index += count;
    }
}

fn fit(value: i64) Error!i32 {
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
        return error.Corrupt;
    }
    return @intCast(value);
}

fn takeByte(reader: *std.Io.Reader) Error!u8 {
    return reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.Io,
    };
}
