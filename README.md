# zig-audio

纯 Zig 的**流式音频解码库**：不依赖 C、不依赖系统解码器、无全局状态、可 fuzz。

**一句话定位**：当 Zig 应用想在不依赖 C、不依赖系统、流式、可 fuzz 的前提下解码几种常见音频格式时，它应该是第一个被想到的库。

> 状态：WAV（PCM / IEEE float / EXTENSIBLE）完整支持；FLAC 子帧集合完整支持：CONSTANT / VERBATIM / FIXED(0–4) / **LPC(1–32 阶)** + Rice 分区、wasted bits、independent 声道，以及 left/side、right/side、mid/side 三种声道去相关。官方 13 个测试向量**全部整文件解码**，与 ffmpeg 逐样本 `max_diff 0`。

## FLAC：完整支持

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 入口 | ✅ | `open` / `openBytes` / `openFile`：`*std.Io.Reader`、内存切片、`std.Io.File` 三个便利入口，错误契约相同 |
| STREAMINFO（块大小、采样率、声道、位深、total samples、MD5） | ✅ | `total_samples == 0` → `Info.total_frames = null` |
| 其它元数据块（padding / seektable / Vorbis comment…） | ✅ | 按长度跳过，遇 last-metadata-block 停止 |
| 帧头（同步码、blocking strategy、8/16 位块大小扩展、采样率编码、声道分配、位深编码） | ✅ | 帧头 CRC-8 校验 |
| 帧尾 CRC-16 | ✅ | 覆盖整帧（含帧头），不一致 → `error.Corrupt` |
| CONSTANT / VERBATIM 子帧 | ✅ | |
| FIXED 0–4 阶 + Rice 分区 | ✅ | 4/5 位参数、partition order、escape code（未压缩分区）、wasted bits |
| LPC 1–32 阶 | ✅ | qlp 系数精度 1–15 位（存储字段 0–14，`0b1111` 禁止）；5 位有符号 shift（负值按左移解码）；预测在 i64 中累加，不按 bps 截断 |
| independent 声道（1–8） | ✅ | 声道顺序原样保留，不混音 |
| left/side、right/side、mid/side | ✅ | side 子帧比源位深多 1 位（right/side 的 side 在**第一个**子帧）；mid/side 用 side 的最低位恢复 `mid` 丢掉的奇偶位；去相关在 wasted bits 展开之后做 |

**LPC 预测语义**（RFC 9639 §9.2.6、附录 A.3/A.4）：`prediction = (Σ coeff[i] × sample[n-1-i]) >> shift`，其中 `Σ` 在 i64 中累加（最坏情况约 33 + 15 + 5 = 53 位），**预测值不按子帧位深截断**——它可能远大于 16 位样本范围，要等加上残差后才落回样本范围；提前截断高位会得到"听起来正常但样本错误"的输出。`shift` 为负时按历史语义左移；规范要求编码器不得写负值，解码端接受它并做了溢出检查。最终样本 + 残差用带溢出检查的加法写入 i32，任何越界都返回 `error.Corrupt`，绝不回绕。

**内存**：`open*()` 按 STREAMINFO 的 max block size 分配一帧的 i32 缓冲（常见 4096×2×4 = 32 KiB，上限 65535×8×4 = 2 MiB），`read()` 之后不再分配；`deinit()` 释放。`openFile*()` 另加一块 64 KiB 的文件读缓冲。

**官方测试向量**：13 个 [ietf-wg-cellar/flac-test-files](https://github.com/ietf-wg-cellar/flac-test-files) 文件**全部整文件解码**，并与 ffmpeg 逐样本 `max_diff 0`。这批文件覆盖 LPC 阶数（subset 范围内）与 qlp 精度 2/15、wasted 1–12、8/12/16 位、1/3/6 声道、三种去相关、总样本数未知（`total_frames = null`）与 escape-code 分区。测试分两层：
1. 官方向量：元数据必须完全正确，整文件样本数等于声明值（`45` 例外，按实际解码数），并与 ffmpeg 逐样本一致；`60` 的 50% 截断必须返回 `error.Truncated`；
2. 位深转换、FIXED 0–4 阶、LPC 1–32 阶、qlp precision 1/2/15、负 shift、32 位以上预测和、Rice 分区、escape code、wasted bits 与三种去相关声道由 `src/flac_build.zig` 构造的合成流覆盖（`src/flac_lpc_test.zig`），并与 ffmpeg 的解码结果对齐。

`61 - predictor overflow check` 的预测值达到 860128（远超 16 位样本范围），而累加和最大约 8.8×10⁸；它检验的是"预测值不能按 bps 截断"，不是 32 位累加和溢出。真正超过 32 位的累加和由合成用例覆盖：`Σ = 32 × 16383 × 32767 = 17178296352`（约为 2³⁴、i32 上限的 8 倍），i32 回绕会预测出 −48 而不是 524240。

## 这不是 Zig 版 FFmpeg

这个库只做**一件事**：把一个已经拿到的音频字节流解码成交错 PCM。它不是多媒体框架，也永远不会长成 FFmpeg。

### 不做清单（以下这些**永不支持**）

| 不做 | 为什么永不支持 |
| --- | --- |
| 视频/图像解码 | 视频在 Windows / macOS / Linux 上都有系统解码器（Media Foundation + D3D11VA、VideoToolbox、VA-API），硬解、色彩管理和帧调度是平台强项；重写一遍只会更慢、更脆。 |
| 音频编码 / 转码 | 编码要码率控制、心理声学模型和大量格式组合，是另一条产品线；解码器的价值恰恰在于把这件事排除在外。 |
| 滤镜、重采样、混音图 | 这些是 DSP 策略，应该由调用方或专门的 DSP 库决定；解码器只负责把字节变成采样，不替调用方改变声音。 |
| 容器多路复用 / 解复用（MP4、MKV 的轨道、时间轴、编辑列表） | 本库只读**单个音频流的负载**。容器是另一个抽象层，混进来会把“可 fuzz 的小解析器”变成“半个播放器”。 |
| 网络协议（HTTP、HLS、DASH、RTSP） | 网络、重试、缓存、鉴权都由调用方处理；库只接受一个 `std.Io.Reader`，不碰 socket，也不做请求。 |
| CLI / ffmpeg 命令行参数兼容 | 这不是命令行工具。目标 API 是 Zig 函数调用；模仿 `ffmpeg -i ... -af ...` 的参数方言与库的边界无关。 |

这些“永不支持”不是当前版本的偷懒，而是产品的边界：**边界越窄，流式、无分配、可 fuzz 才守得住。**

## 为什么只做音频

视频已经有系统解码器：Windows 的 Media Foundation + D3D11VA、macOS 的 VideoToolbox、Linux 的 VA-API 都能硬解，而且视频专利池复杂、格式迭代快。再写一个纯 Zig 视频解码器，投入产出比很差。

音频不一样：Windows 上 WASAPI 只负责**输出**，系统并不带 FLAC / Opus 解码器；macOS 的 AudioToolbox 对 FLAC 的支持也随版本和容器而变。一个应用如果想“走到哪都能放 FLAC”，最后往往还是得自带解码器。音频格式的专利面也窄得多（FLAC、Opus 都是开放、免专利的），维护成本比视频低一个数量级。

所以这里只做音频：**WAV 已完整，FLAC 子帧集合已完整**（官方 13 个向量全部整文件逐样本对齐），Opus 等后续再评估。

## 用法

```zig
const std = @import("std");
const audio = @import("zig_audio");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    var file = try std.Io.Dir.cwd().openFile(io, "music.wav", .{});
    defer file.close(io);

    // 流式：reader 只需要一块自己的缓冲区，不需要把整个文件读进内存。
    var read_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    var dec = try audio.open(std.heap.page_allocator, &file_reader.interface);
    defer dec.deinit();

    // dec.info: 采样率、声道数、源位深、总帧数（未知时 null）
    var pcm: [8192]i16 = undefined;
    while (true) {
        const n = try dec.read(&pcm); // 交错 i16，n == 0 表示结束
        if (n == 0) break;
        // pcm[0..n] 可以直接交给播放器；dec.info.channels 个 i16 为一帧。
    }
}
```

只想知道格式、不想消费流：

```zig
// header 至少 4 字节（FLAC）或 12 字节（WAV）；函数不会读 reader，也不会修改切片。
if (audio.probe(header)) |format| {
    // format == .wav 或 .flac
}
```

已经有整段字节，或只想交出 `std.Io.File`：

```zig
// 不复制 bytes；调用方保证它在 dec.deinit() 之前一直有效。
var dec = try audio.openBytes(allocator, bytes);
defer dec.deinit();

// 流式读文件；库不拥有 file，deinit 不会关闭它（读缓冲 64 KiB）。
var dec2 = try audio.openFile(allocator, file);
defer dec2.deinit();
```

`probe()` 是纯函数；`open()` / `openBytes()` / `openFile()` 都会消费流（`openFile` 从 offset 0 开始）。它们都不“猜”格式：认不出来就是 `error.NotAudio`。

## 接入你自己的文件层

`open()` 只要求一个 `*std.Io.Reader`。这不是“本库不认识你的文件”的借口，而是入口：**任何能按字节产出数据的文件层，都可以用一块自己的缓冲包成 Reader**。不需要把整个文件读进内存，也不需要本库认识你的 `HANDLE`。

### 为什么不要整文件读进来

OTTO 的第一版集成是：`CreateFileW` → 把整个文件读进内存 → `std.Io.Reader.fixed(bytes)`。它能出声，但峰值内存 = 压缩文件 + 解出的 PCM；一个 200 MB 的 FLAC 会先占 200 MB，再叠加 PCM。这正是“流式解码器”最容易自欺的地方：解码器是流式的，喂给它的却是全量缓冲。

`openFile()` 内部也只是 `file.reader(io, &buffer)`（64 KiB）+ `open()`：文件多大都只占这一块读缓冲。测试里用 512 KiB 的 WAV + 128 KiB 的固定分配器验证了这一点——如果实现预读整个文件，`openFile` 会直接 `OutOfMemory`。另一个测试给 `Io` 套了计数 vtable：一个 524332 字节的 WAV 只发了 **68 次**文件读（平均约 7.5 KiB/次），而不是一次 512 KiB——既没有整文件缓冲，也没有按字节读。

### 最小 Reader 骨架

假设你的文件层已经有一个“往 `dst` 写、返回字节数、0 表示 EOF”的函数：

```zig
/// 你的文件层：Win32 HANDLE、自己的预读缓冲、内存映射、网络流……都可以。
/// `readFn` 就是把你已有的读文件函数接上来（I/O 失败返回 error.ReadFailed）。
const Handle = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, dst: []u8) std.Io.Reader.Error!usize,

    fn read(self: Handle, dst: []u8) std.Io.Reader.Error!usize {
        return self.readFn(self.ctx, dst);
    }
};

const HandleReader = struct {
    handle: Handle,
    interface: std.Io.Reader,

    const vtable = std.Io.Reader.VTable{
        .stream = stream,
        .readVec = readVec,
    };

    /// `buffer` 由调用方持有，必须比 Decoder 活得久。
    fn init(handle: Handle, buffer: []u8) HandleReader {
        return .{
            .handle = handle,
            .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn self(r: *std.Io.Reader) *HandleReader {
        return @alignCast(@fieldParentPtr("interface", r));
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const dst = limit.slice(try w.writableSliceGreedy(1));
        const n = self(r).handle.read(dst) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }

    /// Reader 的其余 API（readSliceShort / peekByte / discard …）最终都会
    /// 落到 stream 或 readVec 上。readVec 的契约里有一条容易漏：
    /// `data[0]` 可能长度为 0，此时实现**必须写 Reader.buffer 并返回 0**。
    /// 若返回 0 却什么都不写，fillUnbuffered 会永远循环（OTTO 踩过）。
    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        if (data.len == 0) return 0;

        if (data[0].len != 0) {
            const n = self(r).handle.read(data[0]) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            return n;
        }

        // 没有调用方目的地：填 Reader.buffer，返回 0 是“已填好，不是 EOF”。
        // fillUnbuffered 在调用 readVec 前已经 rebase，保证这里仍有空间。
        const space = r.buffer[r.end..];
        if (space.len == 0) return error.EndOfStream;
        const n = self(r).handle.read(space) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        r.end += n;
        return 0;
    }
};
```

接到本库：

```zig
var my_file: MyFile = .{ .handle = h, .offset = 0 };
const handle = Handle{ .ctx = &my_file, .readFn = MyFile.readSome };

var read_buffer: [64 * 1024]u8 = undefined;
var reader = HandleReader.init(handle, &read_buffer);

var dec = try audio.open(allocator, &reader.interface);
defer dec.deinit();

var pcm: [8192]i16 = undefined;
while (true) {
    const n = try dec.read(&pcm);
    if (n == 0) break;
    // pcm[0..n] 是交错 i16；reader 与 read_buffer 必须活到 dec.deinit()。
}
```

两个常见变体：

- **已经有一整段内存**：用 `openBytes(allocator, bytes)`，它就是 `Reader.fixed` 的糖；**不复制**字节，也不接管它的生命周期。
- **已经是 `std.Io.File`**：用 `openFile(allocator, file)`（单线程阻塞，内部用 `std.Io.Threaded.global_single_threaded`）或 `openFileWithIo(allocator, io, file)`（调用方自带 `Io`，适合并发/取消/自定义事件循环）。库不拥有文件，`deinit` 不关闭它。

## 支持的格式

### WAV：完整支持

| WAV 变体 | 状态 | 说明 |
| --- | --- | --- |
| RIFF/WAVE，PCM 8 位（无符号） | ✅ | 按 WAV 约定 `128 == 静音` |
| PCM 16 / 24 / 32 位 | ✅ | 24 位取高 16 位，32 位右移 16；输出统一为 i16 |
| IEEE float 32 位 | ✅ | clamp 到 [-1, 1]，NaN → 0，±inf → 边界值 |
| `WAVE_FORMAT_EXTENSIBLE`（PCM / IEEE_FLOAT 子格式） | ✅ | 校验 16 字节 GUID |
| 24-in-32（容器 32 位、valid bits 24） | ✅ | 按容器对齐读取，`bits_per_sample` 报 32 |
| 任意采样率 | ✅ | 不重采样，原样报告 |
| 1–64 声道 | ✅ | 原样保留声道数，**不做下混**；>64 声道明确拒绝 |
| 未知 chunk（`LIST` / `fact` / `JUNK` …） | ✅ | 跳过；奇数长度补 1 字节 padding |
| `fmt ` 长度 16 / 18 / 40+ | ✅ | 多余字节跳过；重复 `fmt ` 忽略后一个 |
| `data` 长度 = `0xFFFFFFFF` | ✅ | 视为“读到 EOF”，`total_frames = null`（ffmpeg 写管道时就是这样） |
| `data` 在 `fmt ` 之后、但 `data` 不是最后一个 chunk | ✅ | 找到 `data` 立即开始解码；其后的 chunk 不再扫描 |
| RIFF 长度字段错误 | ✅ | 不依赖 RIFF 长度，按 chunk 自身长度扫描 |

### WAV：明确拒绝（具名错误，不猜）

| 变体 | 错误 | 原因 |
| --- | --- | --- |
| `RIFX`（大端 RIFF） | `error.Unsupported` | 只支持 little-endian RIFF |
| `RF64` | `error.Unsupported` | 64 位长度容器不在当前范围 |
| `WAVE_FORMAT_ADPCM`（0x0002）、A-law（0x0006）、μ-law（0x0007）、MP3（0x0055）等 | `error.Unsupported` | 压缩/有损格式，解码器不内置 |
| PCM 12 / 20 位等非字节对齐位深 | `error.Unsupported` | 只支持 8/16/24/32 |
| IEEE float 64 位 | `error.Unsupported` | 只支持 float32 |
| `data` 在 `fmt ` 之前 | `error.Unsupported` | 流式解码无法回退去重读 `data`；不猜、不缓冲整个文件 |
| 超过 64 声道 | `error.Unsupported` | 明确的工程上限，避免帧大小失控 |
| `block_align` 与声道×位深不一致 | `error.Corrupt` | 头部自相矛盾 |
| `data` 长度不是整帧 | `error.Corrupt` | 半帧不是有效音频 |
| `fmt ` 长度 < 16、EXTENSIBLE 的 cbSize < 22、valid bits 越界 | `error.Corrupt` | 头部结构损坏 |
| 流在头部/数据中途结束 | `error.Truncated` | 不把截断当正常 EOF |
| 多个 `data` chunk | ⚠️ 只解第一个 | 流式解码在第一个 `data` 结束；后续数据忽略 |

### FLAC：明确拒绝（具名错误，不猜）

| 变体 | 错误 | 原因 |
| --- | --- | --- |
| 32 位 FLAC 的 side 声道 | `error.Unsupported` | side 需要 33 位，超出 i32 帧缓冲与 32 位位读取器；明确拒绝而不是截断最高位 |
| 保留的声道分配 11–15、保留的子帧类型、保留的位深/块大小/采样率编码 | `error.Corrupt` | 格式本身不允许 |
| 帧头 CRC-8 或帧尾 CRC-16 不匹配 | `error.Corrupt` | 坏帧不会被当成好音频 |
| 帧的 block size 大于 STREAMINFO 的 max block size | `error.Corrupt` | 头部自相矛盾，且会越过已分配的帧缓冲 |
| 元数据 / 帧中途 EOF | `error.Truncated` | 不把截断当正常结束 |

### 关于 probe

| 输入开头 | `probe()` | `open()` |
| --- | --- | --- |
| `RIFF` … `WAVE` | `.wav` | 尝试按 WAV 打开 |
| `fLaC` | `.flac` | 尝试按 FLAC 打开（支持 CONSTANT / VERBATIM / FIXED / LPC + 三种去相关） |
| `RF64` / `RIFX` + `WAVE` | `null` | `error.Unsupported` |
| 其他 | `null` | `error.NotAudio` |

`probe()` 宁可返回 `null` 也不把“看起来像”的东西当成可解码格式；`open()` 也不接受 `probe()` 不会返回的格式。

## 公共 API

```zig
pub const Format = enum { wav, flac };

pub const Info = struct {
    format: Format,
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16, // 源位深：WAV 报容器位深（float 报 32）；FLAC 报真实位深 4..32
    total_frames: ?u64,   // 头部声明；流式容器/未知总长时为 null
};

pub const Error = error{
    NotAudio,    // 不是本库认识的音频签名
    Unsupported, // 认识但不支持（FLAC 32 位 side 声道、压缩 WAV、RIFX/RF64…）
    Truncated,   // 流在完整头部/帧之前结束
    Corrupt,     // 头部字段自相矛盾、CRC 不符或结构损坏
    OutOfMemory, // open 时分配失败（WAV 不分配；FLAC 分配一帧缓冲）
    Io,          // 底层 Reader 报告 ReadFailed；不是格式错误
    ShortBuffer, // 调用方给的输出缓冲比一帧还小
};

pub fn probe(header: []const u8) ?Format;
pub fn open(allocator: std.mem.Allocator, reader: *std.Io.Reader) Error!Decoder;
pub fn openBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!Decoder;
pub fn openFile(allocator: std.mem.Allocator, file: std.Io.File) Error!Decoder;
pub fn openFileWithIo(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) Error!Decoder;

pub const Decoder = struct {
    info: Info,
    pub fn read(self: *Decoder, out: []i16) Error!usize;
    pub fn deinit(self: *Decoder) void;
};
```

四个入口的区别：

| 入口 | 数据来源 | 生命周期 | `deinit()` 释放什么 |
| --- | --- | --- | --- |
| `open` | 调用方的 `*std.Io.Reader` | reader 必须比 decoder 活得久 | 只释放 decoder 自己的内存 |
| `openBytes` | `bytes` 切片，**不复制** | `bytes` 必须比 decoder 活得久 | reader 记录（不释放 `bytes`） |
| `openFile` | `std.Io.File`，64 KiB 流式读缓冲 | file 必须比 decoder 活得久 | 读缓冲 + reader 记录（**不关 file**） |
| `openFileWithIo` | 同上，但 `Io` 由调用方给 | 同上 | 同上 |

### 契约

- **输出只有一条路径**：交错 i16。8/16/24/32 位 PCM 和 float32 都在解码器内部转换；播放器不需要按源格式分支。
- **调用方给缓冲**：`read()` 只在 `out` 里写，不分配；`open()` / `openBytes()` / `openFile*()` 是仅有的可能使用 allocator 的地方（WAV 不分配帧缓冲，FLAC 按 STREAMINFO 的 max block size 分配一帧 i32 缓冲；两个便利入口还会分配 Reader 状态，`openFile*` 另加 64 KiB 读缓冲）。
- **`read()` 的容量**：能解 `out.len / info.channels` 帧。`out.len` 不是声道数的整数倍时，只解完整帧，尾部 i16 不碰；`out.len == 0` 返回 0；`0 < out.len < channels` 返回 `error.ShortBuffer`。
- **返回的是写入的 i16 个数**，一定是 `channels` 的整数倍；`0` 表示流结束。
- **FLAC 的前缀语义**：如果某一帧失败（CRC、截断、32 位 side），此前已经解出的样本会先返回；下一次 `read()` 返回同一个错误。调用方既能拿到合法音频，也能看到具名失败，而不是被“半段静音”糊弄。
- **声道原样保留**：不做下混、不做上混、不做采样率转换。5.1 就是 6 声道。
- **reader / 文件生命周期**：`open` 的 `reader` 由调用方持有；`openBytes` 的 `bytes` 不被复制；`openFile*` 的 `file` 不被关闭。三者都必须比 `Decoder` 活得久，`deinit()` 只释放 decoder 自己分配的东西。
- **错误后不复用**：`read()` 返回任何错误后，这个 decoder 的状态不再保证，直接 `deinit()`；不要用“再读一次”来探测错误是否消失。
- **入口会消费流**：`open()` 读取 12 字节签名并扫描元数据/chunk，直到首个音频帧（WAV 是 `data` 负载，FLAC 是第一帧）起点；`openFile*` 用 positional reader 从 offset 0 开始；失败时也可能已经消费了最多 12 字节（甚至更多头部）。想先判断而不消费，用 `probe()`（需要调用方自己准备那几字节）。
- **错误不吞**：截断、损坏、不支持、I/O 失败分别有具名错误；不使用 `catch {}` 把问题变成静音。

### PCM 输出规则（逐比特可复现）

`read()` 只输出一种格式：**交错、帧优先的 i16**。第 `f` 帧第 `c` 声道在 `out[f * channels + c]`，一帧内声道顺序与源文件一致。

| 源格式 | 转换规则 | 说明 |
| --- | --- | --- |
| WAV 8-bit unsigned PCM | `(byte - 128) << 8` | 128 → 0，0 → -32768，255 → 32512 |
| WAV 16-bit PCM | 原样复制 | 逐位不变 |
| WAV 24-bit PCM | 算术右移 8 位（丢低 8 位） | 与 ffmpeg `-f s16le` 一致；不是四舍五入 |
| WAV 32-bit PCM | 算术右移 16 位（丢低 16 位） | 同上 |
| WAV float32 | clamp 到 [-1, 1]，NaN → 0，±inf → ±满量程；`round(x * 32768)`，`1.0` → 32767 | float 源的舍入不属于 WAV 格式，允许与其它实现差 1 LSB |
| FLAC 8-bit | `sample << 8`（**有符号**） | 0 → 0，-128 → -32768，127 → 32512；没有 WAV 的 128 偏置 |
| FLAC 12-bit | `sample << 4` | 12 位源占满 i16 |
| FLAC 16-bit | 原样复制 | |
| FLAC 20-bit | 算术右移 4 位 | 取高 16 位 |
| FLAC 24-bit | 算术右移 8 位 | 取高 16 位，与 ffmpeg `-f s32le >> 16` 一致 |
| FLAC 32-bit | 算术右移 16 位 | |

FLAC 的通式：`bits <= 16` 时左移 `16 - bits`，`bits > 16` 时算术右移 `bits - 16`；`Info.bits_per_sample` 始终报告真实源位深，不因为输出是 i16 而改变。

- 声道顺序按源文件原样保留（WAV/FLAC 的标准声道顺序），不做下混、上混或矩阵变换。
- 输出是 native `i16`（当前所有 CI 目标都是 little-endian）；和 ffmpeg `-f s16le` 对比时按 little-endian 写字节。
- 整数 PCM 的转换与 ffmpeg **逐样本一致**，由 `src/compare.zig` 在集成测试里验证；FLAC 的 8/12/20/24/32 位由合成流与 ffmpeg 交叉验证（`src/flac_test.zig`）。

### 与最初草稿的差异（以及原因）

1. `Error` 增加 `Io` 与 `ShortBuffer`。前者把底层 Reader 的传输失败与“字节内容损坏”分开，后者让“输出缓冲比一帧还小”变成具名错误，而不是伪装成 EOF 的 `0`。
2. `read()` 的帧容量按 `out.len / channels` 计算（草稿注释里的 `channels * 2` 是按字节算的；`out` 是 `i16` 切片，所以按元素算）。
3. `Info.bits_per_sample` 明确是**源位深**。WAV 报容器位深（24-in-32 报 32；EXTENSIBLE 的 valid bits 不单独暴露）；FLAC 报真实的 4..32 位，因为输出统一 i16 后仍需要这个值来计算移位。
4. 不做多声道下混。OTTO 的播放路径下混到立体声，因为 WASAPI 共享模式需要；解码库应该把 5.1 原样交给调用方，由播放策略决定。
5. `open()` 自己读 12 字节做格式分派，不依赖 `Reader.buffer.len >= 12`，因此任意小缓冲的 Reader 都能用。`probe()` 保持纯切片接口。
6. `deinit()` 不带 allocator 参数；allocator 在 `open()` 时存进 decoder，FLAC 的帧缓冲释放不需要调用方再传一次。
7. FLAC 的帧级错误采用**前缀语义**：先把已解出的样本返回，再在下一次 `read()` 返回错误。否则调用方拿到的只有"整块失败"，一个 4000 帧的正常前缀就白解了。

## 设计原则

- **流式**：`open()` 只读到首个音频帧起点，`read()` 按调用方的缓冲大小推进；`openFile()` 用 64 KiB 读缓冲，不把整个文件读进内存。
- **调用方提供缓冲**：`read()` 没有隐藏分配，也没有内部 PCM 环形缓冲。
- **解码器无全局状态**：没有单例、没有线程局部缓存、没有全局注册表；两个 decoder 可以并发解不同的流。唯一的例外是 `openFile()` 这个不带 `Io` 的便利入口——它必须从某处拿到 `Io`，使用的是 std 的 `Threaded.global_single_threaded`（单线程、阻塞）。需要并发、取消或自定义事件循环时，用 `openFileWithIo()` 或 `open()`。
- **无分配（或显式 allocator）**：WAV 解码零分配；FLAC 在 `open*()` 用调用方的 allocator 分配**一帧**的 i32 缓冲；`read()` 永远不分配；`deinit()` 释放。
- **显式错误**：`NotAudio` / `Unsupported` / `Truncated` / `Corrupt` / `Io` / `OutOfMemory` / `ShortBuffer`；没有“静音代替错误”。
- **可 fuzz**：解析器只接受 `[]const u8` 和 `std.Io.Reader`，没有文件系统、线程、时间依赖；`zig build fuzz` 对合法 WAV 和合法 FLAC 各做一半随机变异，断言不 panic、不越界、错误具名。

## 构建与测试

需要 **Zig 0.17.0**。零外部依赖、零 C、禁止 `@cImport`。

```sh
zig build            # 编译库（static lib 到 zig-out/）
zig build test       # 单元 + API + fixture + ffmpeg 集成 + 1000 轮变异 fuzz
zig build fuzz       # 10000 轮变异 fuzz（WAV 与 FLAC 各一半）
zig build bench      # 10 秒 WAV + 各 20 秒 FLAC（固定预测 / LPC）解码基准（ReleaseFast；低于目标会失败）
```

集成测试会尝试调用本机 ffmpeg（Windows 路径写死为开发机上的位置）；路径不存在或不是 Windows 时测试自动 `SkipZigTest`，CI 不依赖 ffmpeg。

除了实时 ffmpeg 测试，仓库还提交了 **0.02 秒的 ffmpeg 生成样本**（`src/fixtures/`，总计约 90 KB）：没有 ffmpeg 的 CI 也能解码真实的 PCM8/16/24/32、float32、5.1 WAV，以及固定预测和 LPC（mono 8 kHz、stereo 44.1 kHz order 32 mid/side）的 FLAC；其中的 stereo LPC 文件还与其同源 WAV 逐样本一致。

- `tools/fetch-vectors.ps1`：把 13 个 [ietf-wg-cellar/flac-test-files](https://github.com/ietf-wg-cellar/flac-test-files) 官方向量下载到 `.zig-cache/vectors/`，逐个做 SHA-256 校验；向量不进 git。向量缺失时 FLAC 测试打印一行说明并 `SkipZigTest`，不会失败。
- `src/compare.zig`：测试辅助。把本库解出的 i16 与 ffmpeg 的 `-f s16le`、`-f s32le >> 16` 逐样本比较，并支持“截断流的可解前缀”对比（60 号向量的 50% 截断用例）。
- `src/flac_build.zig`：测试专用的小型 FLAC 编码器，用来造 CONSTANT / VERBATIM / FIXED / LPC、各种位深、块大小扩展、wasted bits、escape code、LPC 精度/阶数/正负 shift，以及 L/S、R/S、M/S 三种去相关声道的精确用例；不参与库代码。

### 目录

```
src/root.zig        公共 API（probe / open / openBytes / openFile / Decoder）
src/types.zig       公共类型（Format / Info / Error）
src/wav.zig         流式 WAV 解码器
src/flac.zig        流式 FLAC 解码器
src/flac_bits.zig   MSB 位读取 + CRC-8 / CRC-16
src/flac_meta.zig   STREAMINFO 与元数据块循环
src/flac_frame.zig  帧头、子帧、Rice 分区、帧尾 CRC
src/flac_build.zig  测试专用 FLAC 编码器（不进库）
src/bench.zig       WAV + FLAC 基准程序
src/fuzz.zig        变异 fuzzer（同时作为 1000 轮测试运行）
src/compare.zig     与 ffmpeg 逐样本比较的测试辅助
src/fixtures/       提交进仓库的小样本 + 生成命令
src/*_test.zig      单元 / API / fixture / ffmpeg 集成测试
tools/              官方 FLAC 测试向量下载脚本
```

## License

MIT，见 [LICENSE](LICENSE)。作者：TLBtianhu。
