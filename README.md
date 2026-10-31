# zig-audio

纯 Zig 的**流式音频解码库**：不依赖 C、不依赖系统解码器、无全局状态、可 fuzz。

**一句话定位**：当 Zig 应用想在不依赖 C、不依赖系统、流式、可 fuzz 的前提下解码几种常见音频格式时，它应该是第一个被想到的库。

> 状态：**v0.1**。WAV（PCM / IEEE float / EXTENSIBLE）已经可用；FLAC 的格式探测与 API 形状已经定下，解码器在下一版实现。当前 `probe()` 能识别 FLAC，`open()` 对 FLAC 返回 `error.Unsupported`。

## 下一轮：FLAC

API 形状已经按 FLAC 的需要定好：

- `Info.total_frames` 可空，对应官方向量 `45 - no total number of samples set.flac`；
- `bits_per_sample` 报告源位深（8/12/16/20/24/32），而不是 WAV 的容器位深；
- `open` 的 allocator 为 FLAC 的查表/状态分配准备，`read` 仍然零分配；
- `Decoder.deinit` 统一释放 decoder 自己持有的内存。

验收标准是**逐比特正确**：`src/compare.zig` 把本库的 i16 输出与 `ffmpeg -f s16le` 逐样本对比，FLAC 轮要求 `max_diff == 0`。13 个官方测试向量由 `tools/fetch-vectors.ps1` 拉到 `.zig-cache/vectors/`；向量缺失时测试打印一行并 `SkipZigTest`。8/12/20 位这类非字节对齐位深的 i16 对齐规则，会在 FLAC 轮用向量和 ffmpeg 对齐后写进 README，而不是现在猜。

特别注意：**WAV 的 8 位 PCM 是无符号（128 = 静音），FLAC 的 8 位是有符号**。FLAC 解码器不能复用上面的 WAV 8 位偏置规则，FLAC 轮会单独定义并用向量验证。

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

这些“永不支持”不是 v0.1 的偷懒，而是产品的边界：**边界越窄，流式、无分配、可 fuzz 才守得住。**

## 为什么只做音频

视频已经有系统解码器：Windows 的 Media Foundation + D3D11VA、macOS 的 VideoToolbox、Linux 的 VA-API 都能硬解，而且视频专利池复杂、格式迭代快。再写一个纯 Zig 视频解码器，投入产出比很差。

音频不一样：Windows 上 WASAPI 只负责**输出**，系统并不带 FLAC / Opus 解码器；macOS 的 AudioToolbox 对 FLAC 的支持也随版本和容器而变。一个应用如果想“走到哪都能放 FLAC”，最后往往还是得自带解码器。音频格式的专利面也窄得多（FLAC、Opus 都是开放、免专利的），维护成本比视频低一个数量级。

所以这里只做音频：**WAV 先行，FLAC 下一版；Opus 等 FLAC 稳定后再评估。**

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

`probe()` 是纯函数；`open()` 会消费流。两者都不“猜”格式：认不出来就是 `error.NotAudio`。

## 支持的格式（v0.1）

### 明确支持

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

### 明确拒绝（具名错误，不猜）

| 变体 | 错误 | 原因 |
| --- | --- | --- |
| `RIFX`（大端 RIFF） | `error.Unsupported` | 只支持 little-endian RIFF |
| `RF64` | `error.Unsupported` | 64 位长度容器不在 v0.1 范围 |
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

### 关于 probe

| 输入开头 | `probe()` | `open()` |
| --- | --- | --- |
| `RIFF` … `WAVE` | `.wav` | 尝试按 WAV 打开 |
| `fLaC` | `.flac` | v0.1：`error.Unsupported`（解码器下一版） |
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
    bits_per_sample: u16, // 源容器的位深（float 报 32；EXTENSIBLE 的 valid bits 不单独暴露）
    total_frames: ?u64,   // 头部声明；流式容器未知时为 null
};

pub const Error = error{
    NotAudio,    // 不是本库认识的音频签名
    Unsupported, // 认识，但这一版/永远不支持（FLAC 解码器、压缩 WAV、RIFX/RF64…）
    Truncated,   // 流在完整头部/帧之前结束
    Corrupt,     // 头部字段自相矛盾或 chunk 结构损坏
    OutOfMemory, // open 时分配失败（WAV 当前不分配；FLAC 会）
    Io,          // 底层 Reader 报告 ReadFailed；不是格式错误
    ShortBuffer, // 调用方给的输出缓冲比一帧还小
};

pub fn probe(header: []const u8) ?Format;
pub fn open(allocator: std.mem.Allocator, reader: *std.Io.Reader) Error!Decoder;

pub const Decoder = struct {
    info: Info,
    pub fn read(self: *Decoder, out: []i16) Error!usize;
    pub fn deinit(self: *Decoder) void;
};
```

### 契约

- **输出只有一条路径**：交错 i16。8/16/24/32 位 PCM 和 float32 都在解码器内部转换；播放器不需要按源格式分支。
- **调用方给缓冲**：`read()` 只在 `out` 里写，不分配；`open()` 是唯一可能使用 allocator 的地方（WAV 目前不分配，FLAC 需要查表）。
- **`read()` 的容量**：能解 `out.len / info.channels` 帧。`out.len` 不是声道数的整数倍时，只解完整帧，尾部 i16 不碰；`out.len == 0` 返回 0；`0 < out.len < channels` 返回 `error.ShortBuffer`。
- **返回的是写入的 i16 个数**，一定是 `channels` 的整数倍；`0` 表示流结束。
- **声道原样保留**：不做下混、不做上混、不做采样率转换。5.1 就是 6 声道。
- **reader 生命周期**：`reader` 由调用方持有，必须比 `Decoder` 活得久；`deinit()` 不关闭 reader。
- **错误后不复用**：`read()` 返回任何错误后，这个 decoder 的状态不再保证，直接 `deinit()`；不要用“再读一次”来探测错误是否消失。
- **`open()` 会消费流**：读取 12 字节 RIFF/fLaC 签名并扫描 chunk，直到 `data` 负载起点；失败时也可能已经消费了最多 12 字节（甚至更多 chunk 头）。想先判断而不消费，用 `probe()`（需要调用方自己准备那几字节）。
- **错误不吞**：截断、损坏、不支持、I/O 失败分别有具名错误；不使用 `catch {}` 把问题变成静音。

### PCM 输出规则（逐比特可复现）

`read()` 只输出一种格式：**交错、帧优先的 i16**。第 `f` 帧第 `c` 声道在 `out[f * channels + c]`，一帧内声道顺序与源文件一致。

| 源格式 | 转换规则 | 说明 |
| --- | --- | --- |
| 8-bit unsigned PCM | `(byte - 128) << 8` | 128 → 0，0 → -32768，255 → 32512 |
| 16-bit PCM | 原样复制 | 逐位不变 |
| 24-bit PCM | 算术右移 8 位（丢低 8 位） | 与 ffmpeg `-f s16le` 一致；不是四舍五入 |
| 32-bit PCM | 算术右移 16 位（丢低 16 位） | 同上 |
| float32 | clamp 到 [-1, 1]，NaN → 0，±inf → ±满量程；`round(x * 32768)`，`1.0` → 32767 | float 源的舍入不属于 WAV 格式，允许与其它实现差 1 LSB |

- 声道顺序按源文件原样保留（WAV 的标准声道顺序），不做下混、上混或矩阵变换。
- 输出是 native `i16`（当前所有 CI 目标都是 little-endian）；和 ffmpeg `-f s16le` 对比时按 little-endian 写字节。
- 整数 PCM 的转换与 ffmpeg **逐样本一致**，并由 `src/compare.zig` 在集成测试里验证；FLAC 下一轮沿用同一规则和同一个 helper。

### 与最初草稿的差异（以及原因）

1. `Error` 增加 `Io` 与 `ShortBuffer`。前者把底层 Reader 的传输失败与“字节内容损坏”分开，后者让“输出缓冲比一帧还小”变成具名错误，而不是伪装成 EOF 的 `0`。
2. `read()` 的帧容量按 `out.len / channels` 计算（草稿注释里的 `channels * 2` 是按字节算的；`out` 是 `i16` 切片，所以按元素算）。
3. `Info.bits_per_sample` 明确是**容器位深**。24-in-32 报 32；EXTENSIBLE 的 valid bits 不单独暴露（v0.1 不需要，FLAC 也不存在这个区分）。
4. 不做多声道下混。OTTO 的播放路径下混到立体声，因为 WASAPI 共享模式需要；解码库应该把 5.1 原样交给调用方，由播放策略决定。
5. `open()` 自己读 12 字节做格式分派，不依赖 `Reader.buffer.len >= 12`，因此任意小缓冲的 Reader 都能用。`probe()` 保持纯切片接口。
6. `deinit()` 不带 allocator 参数；allocator 在 `open()` 时存进 decoder，FLAC 的查表释放不需要调用方再传一次。

## 设计原则

- **流式**：`open()` 只读到 `data` 起点，`read()` 按调用方的缓冲大小推进；不把整个文件读进内存。
- **调用方提供缓冲**：`read()` 没有隐藏分配，也没有内部 PCM 环形缓冲。
- **无全局状态**：没有单例、没有线程局部缓存、没有全局注册表；两个 decoder 可以并发解不同的流。
- **无分配（或显式 allocator）**：WAV 解码零分配；`read()` 永远不分配；FLAC 的解码表在 `open()` 用调用方的 allocator 分配，`deinit()` 释放。
- **显式错误**：`NotAudio` / `Unsupported` / `Truncated` / `Corrupt` / `Io` / `OutOfMemory` / `ShortBuffer`；没有“静音代替错误”。
- **可 fuzz**：解析器只接受 `[]const u8` 和 `std.Io.Reader`，没有文件系统、线程、时间依赖；`zig build fuzz` 对合法 WAV 做随机变异，断言不 panic、不越界、错误具名。

## 构建与测试

需要 **Zig 0.17.0**。零外部依赖、零 C、禁止 `@cImport`。

```sh
zig build            # 编译库（static lib 到 zig-out/）
zig build test       # 单元 + API + ffmpeg 集成 + 1000 轮变异 fuzz
zig build fuzz       # 10000 轮变异 fuzz
zig build bench      # 10 秒 16-bit 立体声 WAV 解码基准（ReleaseFast；低于 200x 实时会失败）
```

集成测试会尝试调用本机 ffmpeg（Windows 路径写死为开发机上的位置）；路径不存在或不是 Windows 时测试自动 `SkipZigTest`，CI 不依赖 ffmpeg。

除了实时 ffmpeg 测试，仓库还提交了 **0.02 秒的 ffmpeg 生成样本**（`src/fixtures/`，总计 72 KB）：没有 ffmpeg 的 CI 也能解码真实的 PCM8/16/24/32、float32、5.1 WAV，以及为下一轮准备的 FLAC 文件。

- `tools/fetch-vectors.ps1`：把 13 个 [ietf-wg-cellar/flac-test-files](https://github.com/ietf-wg-cellar/flac-test-files) 官方向量下载到 `.zig-cache/vectors/`，逐个做 SHA-256 校验；向量不进 git。向量缺失时 FLAC 测试打印一行说明并 `SkipZigTest`，不会失败。
- `src/compare.zig`：测试辅助。把本库解出的 i16 与 ffmpeg `-f s16le` 的输出逐样本比较，返回最大差值/首个差异位置。该文件同时演示了 FLAC 轮“逐比特正确”的验收方式。

### 目录

```
src/root.zig        公共 API（probe / open / Decoder）
src/types.zig       公共类型（Format / Info / Error）
src/wav.zig         流式 WAV 解码器
src/bench.zig       基准程序
src/fuzz.zig        变异 fuzzer（同时作为 1000 轮测试运行）
src/compare.zig     与 ffmpeg -f s16le 逐样本比较的测试辅助
src/fixtures/       提交进仓库的小样本 + 生成命令
src/*_test.zig      单元 / API / fixture / ffmpeg 集成测试
tools/              官方 FLAC 测试向量下载脚本
```

## License

MIT，见 [LICENSE](LICENSE)。作者：TLBtianhu。
