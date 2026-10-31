//! LSB-first bit reader for Vorbis packets.
//!
//! This is deliberately *not* `flac_bits.BitReader`. Vorbis packs bits into
//! each octet least-significant bit first, and a multi-bit field is assembled
//! with the first bit read as its least significant bit. FLAC and MP3 use the
//! opposite order (first bit read is the most significant), so sharing one
//! reader would silently invert every setup-header field.
//!
//! Example: the octet 0xB5 (`1011_0101`) read four bits at a time yields
//! `0x5` then `0xB` here, while an MSB-first reader yields `0xB` then `0x5`.

const std = @import("std");
const types = @import("types.zig");

pub const Error = types.Error;

pub const BitReader = struct {
    data: []const u8,
    /// Absolute bit position, 0 = least significant bit of `data[0]`.
    bit: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn bitsRemaining(self: BitReader) usize {
        return self.data.len * 8 - self.bit;
    }

    /// Read `n` bits (0..32), first bit read becomes the least significant bit.
    pub fn readBits(self: *BitReader, n: u6) Error!u32 {
        if (n == 0) return 0;
        if (self.bitsRemaining() < n) return error.Truncated;
        var value: u64 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const byte = self.data[self.bit >> 3];
            const shift: u3 = @intCast(self.bit & 7);
            value |= @as(u64, (byte >> shift) & 1) << @intCast(i);
            self.bit += 1;
        }
        return @intCast(value);
    }

    pub fn readBit(self: *BitReader) Error!u1 {
        return @intCast(try self.readBits(1));
    }

    /// Read 32 bits and reinterpret them as an IEEE-754 binary32, the
    /// `float32_unpack` the codebook minimum/delta fields use.
    pub fn readF32(self: *BitReader) Error!f32 {
        return @bitCast(try self.readBits(32));
    }

    pub fn skipBits(self: *BitReader, count: usize) Error!void {
        if (self.bitsRemaining() < count) return error.Truncated;
        self.bit += count;
    }
};

/// `ilog` from the Vorbis specification: number of bits needed to represent
/// `value` (`ilog(0) == 0`).
pub fn ilog(value: u32) u6 {
    if (value == 0) return 0;
    return @intCast(32 - @clz(value));
}

/// Largest integer `v` such that `v^dimensions <= entries`, the implicit
/// lattice size of a Vorbis lookup type 1 codebook.
pub fn lookup1Values(entries: u32, dimensions: u16) u32 {
    if (entries == 0) return 0;
    if (dimensions <= 1) return entries;
    var v: u32 = 1;
    while (true) {
        if (v == std.math.maxInt(u32)) return v;
        const next = v + 1;
        var product: u64 = 1;
        var i: u16 = 0;
        while (i < dimensions) : (i += 1) {
            // `product <= entries` on every iteration, and `next` fits u64, so
            // this comparison replaces the multiply that could overflow for a
            // large dimensions value.
            if (product > entries / next) {
                product = @as(u64, entries) + 1;
                break;
            }
            product *= next;
        }
        if (product > entries) return v;
        v = next;
    }
}
