//! One MPEG-1 Layer III granule: side-info structures, scalefactors,
//! requantization, reordering and the hand-off to the synthesis filter.

const std = @import("std");
const types = @import("types.zig");
const tables = @import("mp3_tables.zig");
const bits = @import("mp3_bits.zig");
const huff = @import("mp3_huffman.zig");
const synth = @import("mp3_synth.zig");

pub const Error = types.Error;

pub const GranuleInfo = struct {
    part2_3_length: u16,
    big_values: u16,
    global_gain: u8,
    scalefac_compress: u8,
    block_type: u2,
    mixed: bool,
    table_select: [3]u8,
    subblock_gain: [3]u8,
    region0: u8,
    region1: u8,
    preflag: bool,
    scalefac_scale: u1,
    count1table_select: u1,
    /// Only granule 1 carries scfsi bits; granule 0 transmits everything.
    scfsi: u8,
};

pub const SideInfo = struct {
    main_data_begin: u16,
    granules: [2]GranuleInfo,
};

pub fn parseSideInfo(si: []const u8) Error!SideInfo {
    if (si.len < 17) return error.Corrupt;
    var br = bits.BitReader.init(si);
    var side: SideInfo = undefined;
    side.main_data_begin = @intCast(br.read(9));
    _ = br.read(5); // private bits
    const scfsi: u8 = @intCast(br.read(4));

    for (0..2) |g| {
        var info: GranuleInfo = undefined;
        info.part2_3_length = @intCast(br.read(12));
        info.big_values = @intCast(br.read(9));
        if (info.big_values > 288) return error.Corrupt;
        info.global_gain = @intCast(br.read(8));
        info.scalefac_compress = @intCast(br.read(4));
        info.scfsi = if (g == 1) scfsi else 0;
        info.preflag = false;
        info.scalefac_scale = 0;
        info.count1table_select = 0;
        info.region0 = 0;
        info.region1 = 0;
        info.subblock_gain = .{ 0, 0, 0 };
        info.table_select = .{ 0, 0, 0 };

        if (br.read(1) != 0) {
            info.block_type = @intCast(br.read(2));
            if (info.block_type == 0) return error.Corrupt;
            info.mixed = br.read(1) != 0;
            info.table_select[0] = @intCast(br.read(5));
            info.table_select[1] = @intCast(br.read(5));
            info.table_select[2] = 0;
            for (0..3) |i| info.subblock_gain[i] = @intCast(br.read(3));
        } else {
            info.block_type = 0;
            info.mixed = false;
            for (0..3) |i| info.table_select[i] = @intCast(br.read(5));
            info.region0 = @intCast(br.read(4));
            info.region1 = @intCast(br.read(3));
        }
        info.preflag = br.read(1) != 0;
        info.scalefac_scale = @intCast(br.read(1));
        info.count1table_select = @intCast(br.read(1));
        side.granules[g] = info;
    }
    if (br.pos != 136) return error.Corrupt;
    return side;
}

fn exponentScale(exponent: i32) f32 {
    const clamped = std.math.clamp(exponent, -512, 511);
    return tables.two_pow_q[@intCast(clamped + 512)];
}

fn dequant(magnitude: u16, exponent: i32, negative: bool) f32 {
    const table_value = tables.pow43[@min(magnitude, 8207)];
    const v = table_value * exponentScale(exponent);
    return if (negative) -v else v;
}

fn readScaleFactors(
    gi: *const GranuleInfo,
    br: *bits.BitReader,
    prev: ?*const [22]u8,
    out_long: *[22]u8,
) [40]u8 {
    var sf: [40]u8 = @splat(0);
    const slen1 = tables.slen1[gi.scalefac_compress & 15];
    const slen2 = tables.slen2[gi.scalefac_compress & 15];

    if (gi.block_type == 2) {
        var j: usize = 0;
        const n: usize = if (gi.mixed) 17 else 18;
        for (0..n) |_| {
            sf[j] = @intCast(br.read(@intCast(slen1)));
            j += 1;
        }
        for (0..18) |_| {
            sf[j] = @intCast(br.read(@intCast(slen2)));
            j += 1;
        }
        for (0..3) |_| {
            sf[j] = 0;
            j += 1;
        }
    } else {
        var j: usize = 0;
        for (0..4) |group| {
            const n: usize = if (group == 0) 6 else 5;
            const reuse = (gi.scfsi & (@as(u8, 0x8) >> @intCast(group))) != 0;
            if (reuse and prev != null) {
                for (0..n) |i| sf[j + i] = prev.?[j + i];
            } else {
                const width = if (group < 2) slen1 else slen2;
                for (0..n) |i| sf[j + i] = @intCast(br.read(@intCast(width)));
            }
            j += n;
        }
        out_long.* = sf[0..22].*;
    }
    return sf;
}

fn fillExponents(gi: *const GranuleInfo, sr_idx: usize, sf: *const [40]u8, exp: *[576]i16) void {
    // ISO 11172-3 2.4.3.4.8: exponent = global_gain - 210 - 8*subblock_gain
    //            - 2*(scalefac_scale+1)*scalefac, in quarter-exponent units.
    // The scalefactor step is 2^(0.5*(1+scalefac_scale)) -- half a power of two
    // at scalefac_scale=0 -- not a whole one. Using 4*shift here squares the
    // attenuation and was the audible window-switching bug: long blocks with
    // all-zero scalefactors were unaffected, every short block was quiet.
    const gain: i32 = @as(i32, gi.global_gain) - 210;
    const shift: i32 = @as(i32, gi.scalefac_scale) + 1;
    var line: usize = 0;

    if (gi.block_type == 2) {
        var k: usize = 0;
        if (gi.mixed) {
            for (0..8) |sfb| {
                const width = tables.band_long[sr_idx][sfb];
                const s = @as(i32, sf[sfb]) + (if (gi.preflag) @as(i32, tables.pretab[sfb]) else 0);
                const e = gain - 2 * shift * s;
                for (0..width) |_| {
                    exp[line] = @intCast(e);
                    line += 1;
                }
            }
            k = 8;
        }
        const first_band: usize = if (gi.mixed) 3 else 0;
        for (first_band..13) |sfb| {
            const width = tables.band_short[sr_idx][sfb];
            for (0..3) |win| {
                const e = gain - 8 * @as(i32, gi.subblock_gain[win]) - 2 * shift * @as(i32, sf[k]);
                k += 1;
                for (0..width) |_| {
                    exp[line] = @intCast(e);
                    line += 1;
                }
            }
        }
    } else {
        for (0..22) |sfb| {
            const width = tables.band_long[sr_idx][sfb];
            const scale = if (sfb < 21) sf[sfb] else 0;
            const s = @as(i32, scale) + (if (gi.preflag) @as(i32, tables.pretab[sfb]) else 0);
            const e = gain - 2 * shift * s;
            for (0..width) |_| {
                exp[line] = @intCast(e);
                line += 1;
            }
        }
    }
}

fn pairOffsets(sr_idx: usize) [23]u16 {
    var out: [23]u16 = undefined;
    out[0] = 0;
    for (0..22) |i| {
        out[i + 1] = out[i] + tables.band_long[sr_idx][i] / 2;
    }
    return out;
}

fn decodeHuffman(
    gi: *const GranuleInfo,
    sr_idx: usize,
    data: []const u8,
    start: usize,
    end: usize,
    exp: *const [576]i16,
    xr: *[576]f32,
) Error!void {
    var br = bits.BitReader.initWindow(data, start, end);
    var line: usize = 0;
    const offsets = pairOffsets(sr_idx);

    // Huffman region boundaries, in big-value pairs. Long blocks take the two
    // transmitted region counts. Window-switched granules do not transmit them:
    // the first region always ends after `region_count[0] + 1` scalefactor
    // bands, which for block_type 2 is 9 chunks (36 lines) and for start/stop
    // 8 long bands (36 lines) -- 18 pairs either way. Table 2 is never used.
    // Leaving region0/region1 at zero here once sent pairs 2.. onward through
    // the zero table, which silently truncated every start/stop granule.
    var region1: u16 = 18;
    var region2: u16 = 288;
    if (gi.block_type == 0) {
        region1 = offsets[@min(@as(usize, gi.region0) + 1, 22)];
        region2 = offsets[@min(@as(usize, gi.region0) + @as(usize, gi.region1) + 2, 22)];
    }

    var pair: usize = 0;
    while (pair < gi.big_values and line + 1 < 576 and br.pos < end) : (pair += 1) {
        const table_index: usize = if (pair < region1) 0 else if (pair < region2) 1 else 2;
        var ts = gi.table_select[table_index];
        if (gi.block_type == 2 and ts > 31) ts = 0;
        const symbol = huff.decodePair(ts, &br);
        var x: u16 = symbol >> 4;
        var y: u16 = symbol & 15;
        const lb = huff.linbits(ts);
        if (x == 15) x += @intCast(br.read(@intCast(lb)));
        if (x != 0) {
            xr[line] = dequant(x, exp[line], br.readBit() != 0);
        } else {
            xr[line] = 0;
        }
        line += 1;
        if (y == 15) y += @intCast(br.read(@intCast(lb)));
        if (y != 0) {
            xr[line] = dequant(y, exp[line], br.readBit() != 0);
        } else {
            xr[line] = 0;
        }
        line += 1;
    }

    while (line + 3 < 576 and br.pos < end) {
        const quad = huff.decodeQuad(gi.count1table_select, &br);
        for (0..4) |b| {
            if ((quad & (@as(u4, 8) >> @intCast(b))) != 0) {
                xr[line + b] = if (br.readBit() != 0)
                    -exponentScale(exp[line + b])
                else
                    exponentScale(exp[line + b]);
            } else {
                xr[line + b] = 0;
            }
        }
        line += 4;
    }

    while (line < 576) : (line += 1) xr[line] = 0;
    br.pos = end;
}

fn reorder(xr: *[576]f32, sr_idx: usize, mixed: bool) void {
    const start_band: usize = if (mixed) 3 else 0;
    var base: usize = if (mixed) 36 else 0;
    for (start_band..13) |sfb| {
        const width = tables.band_short[sr_idx][sfb];
        // 3 windows of `width` lines; the widest band is 66 (48 kHz), so the
        // scratch has to hold 3 * 66, not one subband's 18.
        var tmp: [3 * 66]f32 = undefined;
        for (0..width) |j| {
            for (0..3) |win| tmp[3 * j + win] = xr[base + win * width + j];
        }
        for (0..3 * width) |i| xr[base + i] = tmp[i];
        base += 3 * width;
    }
}

/// Decode one granule into 576 i16 samples. `out_f32`, when non-null, also
/// receives the same 576 samples before the fixed-point conversion; the SNR
/// tests use it to compare against ffmpeg's `-f f32le` output.
pub fn decodeGranule(
    gi: *const GranuleInfo,
    sr_idx: usize,
    data: []const u8,
    start: usize,
    end: usize,
    prev_sf: ?*const [22]u8,
    out_sf: *[22]u8,
    xr: *[576]f32,
    pcm: *[576]f32,
    overlap: *[32][18]f32,
    synth_state: *synth.SynthState,
    out: *[576]i16,
    out_f32: ?*[576]f32,
) Error!void {
    if (start > end or end > data.len * 8) return error.Corrupt;

    out_sf.* = @splat(0);
    var br = bits.BitReader.initWindow(data, start, end);
    const sf = readScaleFactors(gi, &br, prev_sf, out_sf);
    var exp: [576]i16 = undefined;
    fillExponents(gi, sr_idx, &sf, &exp);

    decodeHuffman(gi, sr_idx, data, br.pos, end, &exp, xr) catch |err| return err;

    if (gi.block_type == 2) {
        reorder(xr, sr_idx, gi.mixed);
        if (gi.mixed) synth.aliasReduce(xr, 1);
    } else {
        synth.aliasReduce(xr, 31);
    }

    synth.imdctGranule(xr, gi.block_type, gi.mixed, overlap, pcm);

    var samples: [576]f32 = undefined;
    synth_state.process(pcm, &samples);
    if (out_f32) |dst| dst.* = samples;
    for (samples, 0..) |value, i| {
        var scaled = value * 32768.0;
        if (std.math.isNan(scaled)) scaled = 0;
        out[i] = @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
    }
}

test "mono side info is exactly 136 bits" {
    var raw: [17]u8 = @splat(0);
    raw[0] = 0;
    raw[2] = 0; // all zero: valid zero-content granules
    const side = try parseSideInfo(&raw);
    try std.testing.expectEqual(@as(u16, 0), side.main_data_begin);
}

test "pair offsets end at 288 pairs" {
    for (0..3) |sr| try std.testing.expectEqual(@as(u16, 288), pairOffsets(sr)[22]);
}
