# zig-audio

纯 Zig 的**流式音频解码库**：不依赖 C、不依赖系统解码器、无全局状态、可 fuzz。

**一句话定位**：当 Zig 应用想在不依赖 C、不依赖系统、流式、可 fuzz 的前提下解码几种常见音频格式时，它应该是第一个被想到的库。

> 状态：WAV（PCM / IEEE float / EXTENSIBLE）完整支持，另加 G.711 µ-law/A-law、IMA ADPCM、Microsoft ADPCM；AIFF（大端 PCM 8/16/24/32）支持；FLAC 子帧集合完整支持：CONSTANT / VERBATIM / FIXED(0–4) / **LPC(1–32 阶)** + Rice 分区、wasted bits、independent 声道，以及 left/side、right/side、mid/side 三种声道去相关。官方 13 个测试向量**全部整文件解码**，与 ffmpeg 逐样本 `max_diff 0`。MP3（MPEG-1 Layer III）支持**单声道 + 立体声 + 联合立体声（mid/side、intensity）**：八个测试向量（32/44.1/48 kHz，CBR 与 VBR，含 40.9 秒真实音乐）整文件对 ffmpeg 的 f32 输出 SNR 118.9–124.0 dB、逐 granule 最大绝对差 < 2e-6，s16 最大 1 LSB，含 short/start/stop 窗口切换与逐帧开关的 joint stereo，见下文。**Ogg Vorbis 完整解码**：容器、三个头包、floor 1 / residue 0-1-2 / 逆耦合 / IMDCT / 重叠相加，两个测试向量整文件对 ffmpeg 的 f32 输出 SNR 131.9–133.4 dB（最大差 < 8e-8）、s16 SNR 98.8–101.0 dB（最大 1 LSB），样本数与 granule 完全一致。**Ogg Opus 现在是「容器 + CELT + SILK + Hybrid 解码」**：`OpusHead` / `OpusTags` / 每个包的 TOC 帧结构 / 时长全部可读，且 **CELT 层（configuration 16–31）真的出 PCM**——粗/细能量、比特分配、PVQ、anti-collapse、立体声 theta、IMDCT、重叠相加、音高后滤波、去加重全部实现，三个纯 CELT 测试向量整文件对 ffmpeg `-f f32le` 的 SNR 为 **140.7 / 140.4 / 141.9 dB**（s16 SNR 102.6–105.3 dB，最大 1 LSB），样本数与 `granule − pre-skip` 完全一致。**SILK 层（configuration 0–11）也真的出 PCM**：VAD/LBRR、增益、LSF→LPC、音高/LTP、shell 激励、再白化、LPC 合成，以及 SILK 特有的 8/12/16→48 kHz 重采样全部实现，纯 SILK 测试向量整文件对 ffmpeg `-f f32le` 的 SNR 为 **145.3 dB**（s16 107.3 dB，最大 1 LSB），样本数与 `granule − pre-skip` 完全一致。**Hybrid（configuration 12–15）也真的出 PCM**：SILK 低频带与 CELT 高频带在同一帧上分别解码、在时域相加，两个混合素材（9 / 10 个 Hybrid 包，夹在 SILK 与 CELT 包之间）整文件对 ffmpeg `-f f32le` 的 SNR 为 **141.9 / 145.4 dB**（s16 105.9 / 106.1 dB，最大 1 LSB），样本数与 `granule − pre-skip` 完全一致；**立体声 SILK / Hybrid 也已打通**，整文件 SNR **144.8 / 139.1 dB**（s16 106.8 / 103.8 dB，最大 1 LSB）。floor 0 未支持。


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

## MP3：MPEG-1 Layer III 单声道 + 立体声（实验中）

已实现：帧同步与头解析、ID3v2/ID3v1/APE/Lyrics3 跳过、Xing/Info + LAME delay/padding、
MPEG-1 单声道与立体声 side info（每 granule 4 个 channel 块）、跨帧 bit reservoir、
ISO Table B.7 的 32 张 Huffman 表（表 0–31，含 linbits 与 count1 A/B）、scalefactors、
反量化、joint stereo（mid/side 与 intensity，含 `is_pos` 0–7）、short block 重排、抗混叠、
18/12 点 IMDCT、频率反转、32 子带多相合成（每声道一条），以及 gapless 裁剪
（delay + 529 样点滤波器延迟）。

| 能力 | 状态 |
| --- | --- |
| MPEG-1 Layer III / 单声道 | ✅ |
| MPEG-1 Layer III / 立体声（`mode` 00/10，两声道独立） | ✅ |
| MPEG-1 Layer III / 联合立体声（`mode` 01）：mid/side、intensity | ✅ |
| MPEG-2/2.5、Layer I/II | `error.Unsupported` |
| 长块（normal） | 八个向量（单/双声道）逐 granule 与 ffmpeg 相差 < 2e-6（f32），s16 最大 1 LSB |
| short/start/stop 窗口 | 同上；1 秒静音 + 10 ms 脉冲的 start→short→short→stop 回归测试 SNR 121.6 dB |
| intensity stereo | 语料里没有（LAME 不产生 intensity），用 `src/mp3_build.zig` 手工构造的流对 ffmpeg 验证：SNR 122.9 dB |

**立体声顺序**：反量化（两声道）→ joint stereo → 重排 → 抗混叠 → IMDCT → 各自多相合成。
MS 与 intensity 都作用在**反量化后的 `xr`** 上，必须在抗混叠之前：抗混叠是单声道内部相邻谱线的
旋转，先做会把两个声道的混叠项转到错误的邻带上；IMDCT 之后更是时域样本，`M + S` 已不成立。
`mode_extension` 逐帧读取（LAME 会在帧之间开关 MS）。MS-only 帧的 `global_gain` 减 2 个
四分之一指数（1/√2 归一化，编码器放在增益里）；intensity+MS 同时开启时该因子落在 MS 频带上。
`is_pos == 7` 按规范把该频带清零（不是缩放）；ffmpeg 把 ≥7 当作"不是 intensity 位置"并沿用左声道，
这是本库唯一有意与 ffmpeg 不同的地方，合成用例里同时记录了两边的峰值（本库 0，ffmpeg 0.43）。

验收判据（见 `src/mp3_vectors_test.zig`）：f32 与 ffmpeg 比 SNR ≥ 90 dB、逐 granule 最大差 < 1e-4；
s16 比 SNR ≥ 70 dB、最大差 ≤ 8 LSB，且每 20 个 granule 一段的 SNR 不得塌陷；样本总数与 ffmpeg 完全一致
（立体声按每声道计，交错样本数是两倍）。s16 的上限来自两边不同的 i16 舍入规则
（满幅时约 0.5 LSB ≈ 72 dB），所以两条判据不同。

`zig build bench` 的 MP3 行有两条：3 秒 44.1 kHz/128 kbps 单声道文件约 900x 实时，
1 秒 44.1 kHz/128 kbps 立体声文件约 570x 实时（ReleaseFast，两者都远高于 100x 目标）。

## Ogg Vorbis：完整解码

Ogg 容器 + Vorbis I **整条解码链**：三个头包、audio packet、floor 曲线、residue（format 0/1/2）、逆耦合、IMDCT、重叠相加。`open` 返回可读 PCM 的 `Decoder`。Opus 共用同一套容器层，并且 CELT / SILK / Hybrid 三层都做完了，见下面「Ogg Opus：容器 + CELT + SILK + Hybrid 解码」。

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 页面解析（`OggS`、版本、header type、granule、serial、sequence、segment table） | ✅ | 多字节字段小端；保留位非零 → `error.Corrupt` |
| CRC-32（多项式 `0x04C11DB7`，MSB-first，init 0，无 final xor） | ✅ | **每一页都校验**，包括被跳过的逻辑流页面；翻一个页体字节 → `error.Corrupt` |
| packet 拼装（一个 packet 可跨页，255 lacing 续页） | ✅ | 4 MiB 工程上限；悬空 continuation → `error.Truncated` |
| 多逻辑流 | ✅ | 只取**第一个**音频流（按 `\x01vorbis` / `OpusHead` 识别），其余页读过并丢弃；chained 流也忽略 |
| EOS / 页序号 | ✅ | EOS 结束（其后页不再读）；目标流页序号跳号 → `error.Corrupt` |
| Vorbis identification / comment | ✅ | 版本、声道、采样率、bitrate 上限/标称/下限、块大小 `2^n`；comment 的 vendor 与条目跳过 |
| Vorbis setup：码本 | ✅ | ordered / unordered / sparse 三种长度表；lookup type 0/1/2；type 1 的 VQ 表只有 `lookup_values` 个标量 |
| Huffman 解码表 | ✅ | 规范式贪心分配（**同一长度内码字不连续**，所以是 trie 而不是区间查表）+ 10 位快表；内存按*已用*码字计 |
| floor 0 / 1 | ✅ floor 1 / ❌ floor 0 | floor1 走完整预测+曲线合成；用到 floor 0 的流在 `open` 直接 `error.Unsupported`（不假装静音） |
| residue 0 / 1 / 2 | ✅ | **先读完所有 cascade，再按 classification 读 book 列表**（不是交错）；classbook digit 从高下标往低填 |
| mapping / mode | ✅ | mapping type 0、耦合步、submap mux；模式切换的 4 种长窗（normal/start/end/transient） |
| 逆耦合 | ✅ | **在 residue 向量上、按耦合步逆序**做，符号按 `M>0 / A>0` 四个象限走 square-polar 反变换，不是 `M±A` 蝴蝶 |
| IMDCT | ✅ | DCT-IV 经两个 M 点复数 FFT；**无归一化因子**（见下） |
| 重叠相加 | ✅ | 每块输出 `(前块 + 本块)/4` 个样本；首块只用于“预热”，不输出 |
| `Info.total_frames` | ✅ | 流的最后一个 granule；因为要读到末页才知道，`open` 时是 `null`，`read` 到 EOF 后填上 |
| Opus | ✅ 容器 + **CELT + SILK + Hybrid**，**单声道与立体声都支持** | `probe` 返回 `.ogg_opus`；`opus.inspect` 解析 `OpusHead` / `OpusTags` / 每个包的 TOC 与时长；`open` 返回一个真的会解码的 `Decoder`，CELT 包（16–31）、SILK 包（0–11）与 Hybrid 包（12–15）都出 PCM，3 帧以上的包与立体声 Hybrid 在 `read()` 返回 `error.Unsupported`，见下面「Ogg Opus」一节 |

**验收素材**（在仓库外的 `..\zig-audio-vectors\ogg`，不进 git；缺失时打印一行并 `SkipZigTest`）：

| 素材 | 编码 | 声道 | 采样率 | 块大小 | 码本 | floor | residue | mode | total_frames |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `vorbis-44k-q4.ogg` | Vorbis q4 | 2 | 44100 | 256 / 2048 | 42 | 1, 1 | 2, 2 | 2 | 132300 |
| `vorbis-48k-noise.ogg` | Vorbis q6 | 2 | 48000 | 256 / 2048 | 44 | 1, 1 | 2, 2 | 2 | 96000 |
| `opus-48k-96.opus` | Opus 96k | 2 | 48000 | — | — | — | — | — | 144000（见「Ogg Opus」） |
| `opus-48k-mono.opus` | Opus 64k | 1 | 48000 | — | — | — | — | — | 144000（同上） |

**与 ffmpeg 逐样本对比**（整文件，ffmpeg `-f f32le` / `-f s16le`，样本数完全相同）：

| 素材 | f32 SNR | f32 最大差 | s16 SNR | s16 最大差 |
| --- | --- | --- | --- | --- |
| `vorbis-44k-q4.ogg` | **133.42 dB** | 6.7e-08 | **100.96 dB** | 1 LSB |
| `vorbis-48k-noise.ogg` | **131.93 dB** | 7.5e-08 | **98.78 dB** | 1 LSB |

**对齐：没有任何偏移需要裁。** 首块按规范只做预热（它的右半参与下一块的 lap），其后每块吐 `(前块大小 + 本块大小)/4` 个样本；整条流的样本数刚好等于最后一个 granule，末块按 granule 截断。所以**开头不裁、结尾只按 granule 截断**，与 ffmpeg 的 `-f s16le` 输出长度逐样本一致（132300 / 96000）。Vorbis 不像 MP3 有编码器延迟字段，重叠相加的首块丢弃就是它的“编码器预滚”。

**IMDCT 不做归一化**：教科书的 IMDCT 有 `2/M` 因子，Vorbis 没有——`4/n` 在编码器的前向变换上（参考实现 `mdct_forward` 里乘 `scale`），`mdct_backward` 是裸余弦和。这一条不会体现在波形相关性上（整体缩放一个常数相关系数仍是 1.000000），只体现在绝对电平，所以最容易被漏掉；本库在 `vorbis_dsp.zig` 的两个 dsp 测试里对冲，并在报告里写清。

**floor1 的曲线合成必须整表排序**：X 列表里 `x[0]=0`、`x[1]=2^rangebits` 分别是极小值和极大值，但“画曲线”那一步要对**整个** X 列表按升序排，于是 `x[1]` 排到最后、最后才画。如果只排 2..n-1（保留前两个位置不动），曲线形状会整体错位而位流消耗一位不差——这是一个只在听感/SNR 上暴露、在解析测试里完全看不见的 bug。

**位序与 FLAC/MP3 相反**：Vorbis 的位打包是 **LSB-first**（多比特字段的**第一个**读到的位是**最低**位），FLAC/MP3 是 MSB-first。所以 `src/vorbis_bits.zig` 是独立读取器，不复用 `flac_bits.BitReader`。测试里对同一个字节 `0xB5` 做了对照：Vorbis 先读 4 位得到 `0x5`，FLAC/MSB 读取器得到 `0xB`。如果“顺手复用”MSB 读取器，setup 里每个字段都会静默反序。

**`float32_unpack` 不是 `@bitCast`**：码本的 `minimum_value` / `delta_value` 是 1 位符号 + 21 位整数尾数 + 10 位指数（偏置 788），不是 IEEE-754。按 IEEE 位型直读会得到指数离谱的“合法浮点数”（1.0 读成 2^65），音频变成 1e18 量级的噪声而不是报错。

**`zig build bench` 的 Vorbis 行**：3 秒 44.1 kHz/立体声 q4 循环到 20 秒，约 **380x 实时**（目标 100x，ReleaseFast）。

ffprobe 只暴露声道、采样率和时长（正好对上 `total_frames`）；码本 / floor / residue / mode 的数量用一个独立的 Python 参考解析器按 Vorbis I 规范交叉核对。坏 CRC（页体翻一字节）→ `error.Corrupt`；截断（页体切 5 字节）→ `error.Truncated`，两者都在 `read` 阶段报出（`open` 只读头几页，这是流式解码的应有行为）。

### Ogg Opus：容器 + CELT + SILK + Hybrid 解码

Opus 不是一个编码器：它是 **SILK + CELT 两层加一个切换器**，逐包决定用哪一层。三层现在都能出 PCM：**CELT 层（configuration 16–31，音乐）**、**SILK 层（0–11，语音）**，以及把两者放在**同一帧**里的 **Hybrid 层（12–15）**。SILK 与 CELT 共用同一套范围解码器、同一个 pre-skip/granule 裁剪路径，区别是 SILK 在 8/12/16 kHz 上合成再重采样到 48 kHz，而 Hybrid 在一帧里先解 SILK 低频再解 CELT 高频，最后在时域相加。**立体声 Hybrid 仍然返回 `error.Unsupported`**：没有素材，不写没测过的路径。

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| `OpusHead`（RFC 7845 §5.1） | ✅ | magic、version、channels、**pre-skip**（u16 LE）、input sample rate、output gain（Q7.8，i16）、mapping family |
| channel mapping family 0 | ✅ | 单流单声道/立体声；stream count 固定 1、coupled count 固定 `C-1`，不编码 |
| channel mapping family 1 | ✅ | 解析 stream count / coupled count / mapping table（255 = 静音），并校验 `N≥1`、`M≤N`、`M+N≤255`、每个 index `< M+N` 或 `255`；不合法 → `error.Corrupt` |
| family ≥ 2（Ambisonics） | ❌ `error.Unsupported` | 明确拒绝，不静默忽略 mapping table |
| `OpusTags`（RFC 7845 §5.2） | ✅ 校验 magic、跳过后面的 vendor + 条目 | 结构走通（长度自洽），内容不暴露 |
| TOC 帧结构（RFC 6716 §3.2） | ✅ | config / stereo / frame count code 0–3、1–2 字节帧长、padding、每帧大小与偏移 |
| `Info.total_frames` | ✅ | `最后一页 granule − pre_skip`；**granule 含 pre-skip**；与前几轮一样，`open` 时是 `null`，`read` 到 EOF 后填上 |
| **CELT 解码（config 16–31）** | ✅ | 粗能量（frame 级 inter/intra 预测）→ 细能量 → 比特分配 → PVQ 形状 → anti-collapse → 反归一化 → 立体声 theta 重建 → IMDCT → 重叠相加 → 音高后滤波 → 去加重 |
| **SILK 解码（config 0–11）** | ✅ | VAD/LBRR → 增益（绝对+差分）→ LSF（stage-1/2 VQ、反预测、稳定化、LSF→LPC）→ 音高（lag+contour）→ LTP → 激励（pulse/shell、LSB、符号、伪随机翻转）→ 再白化 → LTP 合成 → LPC 合成 → 限幅 → 8/12/16→48 kHz 重采样 |
| **Hybrid 解码（config 12–15）** | ✅ | 一帧内 SILK 占前半段比特、CELT 从 `tell()` 处接着解；CELT 起始频带 17（≈8 kHz）、终止频带按包带宽（SWB 19 / FB 21）；SILK 半边固定按 WB 16 kHz 合成再升 48 kHz，两路**时域相加**；包尾 ≥37 比特时读模式切换的 CELT 冗余帧并做 2.5 ms crossfade |
| **立体声 SILK / Hybrid** | ✅ | SILK 的立体声是 **mid/side**（RFC 6716 §4.2.2 的三组预测权 + `silk_stereo_MS_to_LR`），不是两路独立 SILK；Hybrid 立体声 = SILK 的 mid/side 解成 L/R 后**逐声道**升 48 kHz，再加 CELT 自己的立体声，两路分别相加。整文件 SNR：`stereo-silk-24k` **144.83 dB**、`stereo-hybrid-32k` **139.08 dB**（s16 106.8 / 103.8 dB，最大 1 LSB）。原先两端 transient 帧掉到 20–55 dB，是本轮关掉的两个 CELT 解码错误，见下面「已修复」 |
| 每包 3 帧及以上（`code 3`） | ❌ `error.Unsupported` | 多帧打包这一轮不做；只解第一帧等于悄悄丢音频，所以明确拒绝 |
| `open` / PCM | ✅ | 返回可读 PCM 的 `Decoder`；`opus.inspect` 仍提供纯结构视图 |

五个素材（`opus.inspect` 的真实输出，与 `ffprobe -show_entries stream=...` 逐项对齐）：

| 素材 | 声道 | pre_skip | input_rate | gain | family | total_frames | granule（= ffprobe `duration_ts`） | 包数 | 帧/包 | 配置分布 | 本轮可解码 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `opus-48k-128-20ms.opus` | 2 | 312 | 48000 | 0 | 0 | 96000 | 96312 | 101 | 1 | 31 ×101 | ✅ |
| `opus-48k-24-voip.opus` | 1 | 312 | 48000 | 0 | 0 | 96000 | 96312 | 101 | 1 | 9 ×11, 15 ×9, 23 ×80, 27 ×1 | ✅ |
| `opus-48k-64-60ms.opus` | 2 | 312 | 48000 | 0 | 0 | 96000 | 96312 | 34 | 3 | 27 ×31, 31 ×3 | ❌ 3 帧/包 |
| `opus-48k-96.opus` | 2 | 312 | 48000 | 0 | 0 | 144000 | 144312 | 151 | 1 | 31 ×151 | ✅ |
| `opus-48k-mono.opus` | 1 | 312 | 48000 | 0 | 0 | 144000 | 144312 | 151 | 1 | 31 ×151 | ✅ |

**三种编码路径都被触到，而且都能解码**：五个文件合计 CELT 518 包、SILK-only 11 包、Hybrid 9 包（后两者全在 24k VOIP 那个文件里：config 9 = SILK WB 20 ms，config 15 = Hybrid FB 20 ms，config 23/27 = CELT 10/20 ms）。128k/20 ms 与 96k 的音乐素材全是 config 31（CELT 全带 20 ms）。**60 ms 素材是 `code 3` 的 3×20 ms CELT，不是 SILK 长帧**——libopus 在 64k 立体声下选了 CELT，这一点和“长帧就该是 SILK”的直觉相反，表格是按实际字节统计的。

#### 验收：三个纯 CELT 素材对 ffmpeg

| 素材 | 声道 | 帧数 | f32 SNR | f32 最大差 | s16 SNR | s16 最大差 |
| --- | --- | --- | --- | --- | --- | --- |
| `opus-48k-128-20ms.opus` | 2 | 96000 | **140.69 dB** | 2.98e-08 | **104.91 dB** | 1 LSB |
| `opus-48k-96.opus` | 2 | 144000 | **140.42 dB** | 2.98e-08 | **102.63 dB** | 1 LSB |
| `opus-48k-mono.opus` | 1 | 144000 | **141.91 dB** | 3.7e-08 | **105.25 dB** | 1 LSB |

判据（与 MP3/Vorbis 一致）：f32 SNR ≥ 90 dB 且逐样本最大差 < 1e-4；s16 SNR ≥ 70 dB 且最大差 ≤ 8 LSB；样本数与 ffmpeg 完全一致。三个文件全部通过，**样本数 96000 / 144000 / 144000，与 ffmpeg 逐样本数相同**。

为什么 128k / 96k 两个纯 CELT 文件以前只有 94 / 123 dB：**那两处 CELT 解码错误**（折叠区间端点、anti-collapse 声道顺序）只在 transient 帧、并且只在零脉冲频带落到折叠边界时可见，坏帧被 99 个好帧平均掉了；本轮修掉后三个文件都在 140 dB 附近（见下面「已修复」）。另一方面，**两个参考实现自己就对不上**：同一份 ffmpeg 里，原生 CELT 解码器和它静态链接的 libopus 在这些文件上只差 **77.0 / 77.0 / 80.0 dB**（`opus_celt_vectors_test.zig` 里逐文件测出来并断言“我们比 libopus 更接近 ffmpeg”）。原因是 libopus 的 `FLOAT_APPROX` 构建用多项式近似 `celt_exp2`，而 ffmpeg 原生解码器用 `exp2f`，两者在 `denormalise_bands` 里差出约 1e-4 的相对增益，正好是 77 dB 量级。**所以本轮刻意用精确的 `exp2`**：这既是 RFC 的语义，也是比较目标的实现方式。剩下的差（约 4e-8）就是两种浮点求值顺序的舍入。

**pre-skip 对齐结论：裁剪，不是偏移。** ffmpeg `-f f32le` / `-f s16le` 的输出长度恰好是 `granule − pre_skip` = 96000 / 144000，也就是说它把前 312 个样本**丢掉**了，而不是在时间轴上平移。本库做同一件事：解码器算出 `skipped + delivered`，前 `pre_skip` 个样本直接丢，再在末页 granule 处截断（`delivered >= total_frames` 就停）。如果改成“偏移”，整条流会晚 312 个样本 = 6.5 ms，逐样本比对立刻从 141 dB 掉到 0 dB。**末尾还要截断**：包内样本数求和的 96960/144960 比真实长度多出正好一个包（960），末页 granule 把它切掉——这一条和 Vorbis 不同，Vorbis 只截块，Opus 还要按 granule 裁到精确样本数。

**celta 的坑（按出现顺序）**：

1. **比特分配必须先对**。`bits2pulses` 不是对数换算，而是在预计算的脉冲阶梯上二分，且“恰好一半”时向下取；细能量的除法在整除前先加 `den/4`。任何一处差 1/8 bit，后面每个频带的预算都会漂，最后整帧的符号全错。校准办法：先让 `tell()`/`tellFrac()` 与参考完全一致，再用真实素材的 SNR 验证。
2. **`V(N,K)` 必须用 u32 模运算**。宽频带高码率下 `V` 会超出 32 位，编码器因此强制分裂频带；用更宽的整数算“更对”，但会改变索引映射——那就是另一种码本，输出必然是噪声。
3. **立体声 theta 有三种分布**：时间分裂用三角分布、立体声用阶梯分布、其余用均匀分布。选错一种，读到的符号数就不同，之后全盘错位。`itheta == 0` 与 `== 16384` 是特例：前者 mid 拿满、后者 side 拿满，`fill` 掩码也要跟着改。
4. **`SHR16(mid, 1)` 在 float 构建里是恒等宏**。`stereo_merge` 里照抄定点版的“右移 1 位”会让每个样本大 2 倍（+6 dB），而频谱形状、L/R 相关性、逐帧波形看起来全都对，只有绝对电平错——本轮就是被这一条卡住，靠“逐频带能量比恰好 +6.00 dB”定位的。
5. **PVQ 的展开方向**：解码是先取索引再逐步降维（`uprev`），不是从零重建；用 `unext` 正向重算结果一样，但每次都要 O(N·K)。

#### 其它实现细节

**为什么 `sample_rate` 固定 48000**：Opus 的内部带宽可以在 4/6/8/12/20 kHz 之间逐包切换，但输出采样率只有一个基准 48 kHz；RFC 7845 §5.1 明说 input sample rate 字段“**not** the sample rate to use for playback”，它只是编码前原始素材的提示。所以 `Info.sample_rate` 恒为 48000，提示值单独放在 `input_sample_rate` 里，不参与任何计算。

**为什么 pre-skip 必须从 granule 里减掉**：Opus 编码器有算法延迟，解码器开头要丢掉 `pre_skip` 个样本；而 granule position 记的是**含这段延迟**的绝对样本位置。RFC 7845 §4.3 的公式是 `PCM sample position = granule position − pre-skip`。于是 ffprobe 的 `duration_ts`（= granule，96312 / 144312）比真实音频长度（96000 / 144000）多出正好 312 个样本：**`duration_ts = total_frames + pre_skip`**，五个文件全部对上。反过来说，如果直接拿 granule 当长度，每个文件都会多报 6.5 ms；如果拿包内样本数求和，则会**多报**（96960 / 97920 / 144960）——因为末页的 granule 会把最后一个包截短（end trimming），差值恰好不超过一个包（960/1920/2880），测试里对这条也做了断言。

**不伪造静音**：3 帧以上的包在 `read()` 里返回 `error.Unsupported`（立体声 SILK/Hybrid 从这一轮起是支持的，见下）。返回静音只会把“不支持”变成“能播但没声音”，更难排查。`open()` 之所以不拒绝，是因为**包的编码模式写在包里**，头里没有——想知道就得先读包，那就已经是 `read` 了。

**码率不变的是“结构”**：`opus.inspect` 仍然只解析结构、不出 PCM，五个文件与 ffprobe 的 `duration_ts`/`channels`/`sample_rate` 全部对齐，并逐个包核对「帧大小 + framing + padding == 包长」。

合成用例覆盖真实素材没有的分支：`code 1`（两帧等长）、`code 2`（显式帧长，1 字节与 2 字节两种）、`code 3` 的 CBR/VBR、1 字节与多字节（255 续读）padding、`M=0`、120 ms 上限（48×2.5 ms 通过、49×2.5 ms 拒绝）、超过 1275 字节的帧、以及 `OpusHeaX` 式的坏 magic / 坏版本 / 零声道。真实素材里没有 padding，也没有 `code 1/2`，所以这几条只能靠合成包。

CELT 的单元测试按层拆开：PVQ（`V(N,K)` 手算值、`cwrsi` 把 18 个码字恰好枚举一次、脉冲阶梯与 `bits2pulses` 的往返）、能量反量化、比特分配（分配总量不超预算、caps 随声道数单调）、比特精确的 `bitexact_cos`/`isqrt32`、IMDCT（单频点、FFT 峰值位置、尺寸分解）、Hadamard 与 haar 往返、`stereo_merge`。整文件验收在 `src/opus_celt_vectors_test.zig`。

#### SILK：voice 那一半

SILK 是预测编码：一个短时 LPC 滤波器 + 一个长时（音高）预测器，用稀疏脉冲激励驱动。解码顺序是规范的一部分（RFC 6716 §4.2.3–4.2.7），因为每个字段都改变下一个字段要花多少比特：

1. **帧头**：每个 20 ms 帧的 VAD 标志，然后一个 LBRR 标志；40/60 ms 包再跟一个 LBRR 位图；
2. **LBRR 帧**（低码率冗余）：只解比特、不合成——它描述的是更早一帧的副本；
3. **帧类型**：inactive / unvoiced / voiced + 量化偏移（`qoffset_high`）；
4. **增益**：每 5 ms 子帧一个，首子帧绝对编码（6 位对数），其余差分编码；
5. **LSF**：stage-1 索引选出码本与预测权重，stage-2 残差反向后向预测 → 归一化 LSF → 稳定化（最小间距、必要时排序推开）→ LSF→LSP→两个多项式→LPC，再做带宽扩展与 LEVINSON 稳定检查；
6. **音高**：绝对 lag 或相对上一帧的 delta，加 contour 偏移；LTP 五抽头；
7. **激励**：shell 块脉冲计数（含 17 逃逸与 LSB 扩展）、PVQ 二叉树定位、raw LSB、符号、伪随机符号翻转，装配成 Q23；
8. **合成**：系数变化处先**再白化**（把输出跑一遍新滤波器得到残差）、按增益比 `rescale`、LTP、LPC、`±1` 限幅；
9. **重采样**：8/12/16 kHz → 48 kHz，然后交给和 CELT 完全相同的输出路径（pre-skip 裁剪 + 末页 granule 截断）。

**SILK 没有去加重这一步**：去加重（ffmpeg 的 `ff_opus_deemph_weights`、α_p = 0.85）是 **CELT** 输出链的一部分；SILK 合成到 `±1` 限幅就结束了，参考实现（ffmpeg `silk.c` 与 libopus `silk/decode_core.c`）里都没有对 SILK 做去加重。这里按参考实现来——也正因为如此才有 145 dB。

**为什么重采样这一步必须"复刻"而不是"写个好滤波器"**：ffmpeg 原生 Opus 解码器的 SILK 输出是 8/12/16 kHz，它用 `libswresample` 升到 48 kHz（`libavcodec/opus/dec.c` 里 `filter_size=16`、按带宽设输入率、先用几个零样本预热、每包调一次 `swr_convert`）。同一份 SILK 码流，用 libopus 自己的 `silk_resampler` 和用 swresample 差 **47 dB**——比"两个解码器"的差别大得多。所以 `src/opus_silk_resample.zig` 复刻的是 swresample 在该配置下的算术：16 抽头/相位、Kaiser 窗 β=9、cutoff 0.97、按精确有理比取相位数（48/8=6、48/12=4、48/16=3，而不是默认的 1024）、`index/frac` 定点步进、以及启动时"镜像"补历史的那段。预热零样本数按带宽取 4/8/11（NB/MB/WB）。这套东西本身用一个独立探针和 `ffmpeg -af aresample=filter_size=16` 对过：8/12/16 kHz 三个速率上都是 **~144 dB、最大差 9e-8**（就是 f32 舍入）。

**验收（对 `ffmpeg -f f32le` / `-f s16le`）**：

| 素材 | 实际内容 | 帧数 | f32 SNR | f32 max | s16 SNR | s16 max |
| --- | --- | --- | --- | --- | --- | --- |
| `silk-12k-nb.opus` | 101 包全是 config 9 = **SILK WB 20 ms**（名字里的 nb 是码率标签，不是带宽） | 96000 | **145.30 dB** | 2.98e-08 | **107.28 dB** | 1 LSB |
| `silk-10k-nb.opus` | 101 包全是 config 1 = **SILK NB 20 ms**（8 kHz 内部率，测 flush） | 96000 | **144.33 dB** | 2.98e-08 | **107.72 dB** | 1 LSB |
| `silk-14k-nb-40ms.opus` | 51 包全是 config 2 = **SILK NB 40 ms**（每包两个 SILK 帧，测 flush） | 96000 | **144.39 dB** | 2.98e-08 | **107.19 dB** | 1 LSB |
| `stereo-silk-24k.opus` | 91 包 config 9（**SILK WB 20 ms，TOC stereo=1**）+ 1 包 config 13 + 9 包 config 15 | 96000×2 | **144.83 dB** | 4.47e-08 | **106.76 dB** | 1 LSB |
| `stereo-hybrid-32k.opus` | 101 包全是 config 15 = **Hybrid FB 20 ms，stereo=1** | 96000×2 | **139.08 dB** | 4.47e-08 | **103.80 dB** | 1 LSB |

145 dB 不是"勉强过 90 dB"，而是**和比较目标是同一套浮点运算**：SILK 的参数解码是定点（增益、LSF、音高、激励），合成是浮点，ffmpeg 的原生 SILK 也是这个分工。libopus 是全定点合成，两者在同样码流上只差约 40 dB，所以"照 libopus 写"会得到正确但和目标差 40 dB 的输出。

**已修复（本轮）：立体声素材的 transient 帧。** 原先两个立体声素材的首/尾 transient 帧掉到 20–55 dB（整文件 82.91 / 47.05 dB），根因是 **CELT 解码的两个错误叠加**，都不在 SILK、也不在 mid/side：

1. **`quant_all_bands` 的折叠区间端点少算了一位。** libopus 与 ffmpeg 的 `fold_start` 都是先自减再比较（`while (eBands[--fold_start] > target)`），这样“恰好等于 `effective_lowband` 的那个频带”本身可折叠；原来的写法比较的是前一个频带，循环停下时没有把该频带包含进来。`fold_end` 的包含性同样错了一位。于是 `x_cm`（可折叠频带的 collapse mask 并集）取错，零脉冲频带的 `fill`、以及写回的 `collapse_masks` 都跟着错。此外 `collapse_masks` 原来没有逐帧清零（ffmpeg 每帧 `memset`）；折叠区间错时它还会把上一帧的掩码读进来，让错值更不可预测。这一条主要打中立体声 / 混合帧：Hybrid 的 `effective_lowband` 总被钳到 `e_bands[17]`，正好落在频带边界上，所以每个 Hybrid 帧都在 band 18–20 命中；单声道素材修复前后都是 141.9 dB，没有踩到这条。
2. **anti-collapse 的循环嵌套。** ffmpeg 是 **channel-major**（每声道调用一次 `process_anticollapse`，两个声道共享 `f->seed`），libopus 是 band-major / channel-inner；这里原来照 libopus 写。噪声幅度 `r`、`prev_energy` 的两代历史、seed 来源都与 ffmpeg 逐位一致（用带 `fprintf` 的本地 ffmpeg 调试版逐频带对过），只有 LCG 序列分配给哪个 (band, channel) 不同——对 42 个 transient 帧里 `r > 0` 的那些，这决定了注入噪声的符号。既然验收目标是 ffmpeg，这里改成 channel-major。

修好后 `stereo-silk-24k` / `stereo-hybrid-32k` 整文件 **144.83 / 139.08 dB**（s16 106.76 / 103.80 dB，最大 1 LSB），交付的每一包都 ≥ 137.7 dB；两个文件回到 90 dB 判据，不再按实测值记录。**为什么能躲过之前的 1525 帧素材**：transient 帧只有 42/1525，anti-collapse 只在那里跑；而折叠端点的错误只在“频带零脉冲 + 折叠边界恰好落在频带边界”时可见，纯 CELT 素材里只有最后一个低码率帧满足；128k 那个文件整文件仍有 94.25 dB（其余 100 帧 140 dB），所以一直过线。
**素材实况**：任务给的三个"SILK 素材"里只有一个是纯 SILK，另两个是混合模式。Hybrid 做完之后它们都能整文件解码，所以三个文件现在都是验收素材（混合那两个的完整数字在下面「Hybrid」一节）：

| 素材 | config 分布 | 第一个包 | 现在 |
| --- | --- | --- | --- |
| `silk-12k-nb.opus` | 9 ×101 | SILK | ✅ 纯 SILK（而且是 **WB**，不是 NB），145.30 dB |
| `silk-20k-wb.opus` | 9 ×91, 13 ×1, 15 ×9 | **Hybrid（config 15）** | ✅ 91 SILK + 10 Hybrid，145.36 dB |
| `opus-48k-24-voip.opus` | 9 ×11, 15 ×9, 23 ×80, 27 ×1 | **Hybrid（config 15）** | ✅ 11 SILK + 9 Hybrid + 81 CELT，141.90 dB |

`silk-20k-wb.opus` 的结构特别有用：9 个 Hybrid 打头、91 个 SILK 中段、最后 1 个 **10 ms** Hybrid（config 13，SWB）收尾——10 ms 混合路径只有这里摸得到。`opus-48k-24-voip.opus` 则在第 19 个包（SILK config 9）的包尾塞了一个 CELT 冗余帧，正好覆盖 SILK→CELT 的模式切换 crossfade。为了让 NB/MB 与 40/60 ms 分支也有验收，本轮另外用 libopus 编了几条**纯 SILK** 素材（本地，不入库）交叉验证：

| 本地素材 | config | 帧数 | f32 SNR |
| --- | --- | --- | --- |
| `gen-x7000-0.opus`（8 kbps NB 20 ms） | 1 | 96000 | 40.13 dB（见下） |
| `gen-x11000-6000.opus`（11 kbps MB 20 ms） | 5 | 96000 | **144.18 dB** |
| `gen-mb40.opus`（NB 40 ms，2 个 SILK 帧） | 2 | 96000 | 46.02 dB（见下） |
| `gen-wb60.opus`（WB 60 ms，3 个 SILK 帧） | 11 | 96000 | **144.66 dB** |

**8 kHz 的尾巴现在是 144 dB，不是 40 dB**（这一轮修掉的）：上一轮两条 8 kHz 素材的差异**只在最后 24 个样本**（第 95976..96000 个），前面的子帧全是 143–145 dB。原因是 swresample 在 8 kHz 这条路径上每个包少产几个样本，累计的 `delayed_samples` 最后由 `resample_flush` 补：它把缓冲区里最后 `(min(count, 16)+1)/2` 个输入样本**镜像**一份接在后面，让滤波器把还欠的输出算完。复刻要点三个：(1) 镜像规则（`in_buffer[count+j] = in_buffer[count-1-j]`），(2) `swr_convert(NULL)` 会同时清掉 `resample_in_constraint`（不清就一个样本都出不来），(3) **这段尾巴在 granule 截断之后才发**——ffmpeg 的容器层只把最后一个包截到 granule，drain 出来的 flush 帧排在它后面，所以整流的最后 `delayed_samples` 个样本是 flush 而不是包内样本。三条都对上以后，`silk-10k-nb.opus` 与 `silk-14k-nb-40ms.opus` 的整文件 SNR 都是 **144 dB、最大差 3e-8**（逐样本全等），`opus_silk_resample.zig` 里也留了两条单测钉住镜像规则和"flush 恰好补上欠的样本数"。

**SILK 的坑（按出现顺序）**：

* **`nlsf_interp_factor` 忘了存回解码器**：`lpc.decode` 把插值因子作为返回值交出来，而合成读的是 `self.interp_factor`。结果 20 ms 帧的前两个子帧（用插值 lead-in）完全正确、后两个子帧用错分支——症状极其有迷惑性：第一个包 145 dB、第二个包从第 2 个子帧起掉到 13 dB，随后的包慢慢"自愈"到 100 dB。这类"字段既是返回值又是状态"的移植错误只有逐子帧 SNR 才看得出来。
* **输出的 −2 偏移**：参考实现取的是 `frame.output[SILK_HISTORY − flength − 2]`，比"刚写的那一帧"早 2 个样本。这不是笔误，是一个真实的 2 样本提前量；照直觉写成 `−flength` 会让整条流晚 2 个样本，SNR 直接从 145 dB 掉到 ~25 dB。
* **10 ms MB 的 shell 块多出 8 个样本**：`shell_blocks[MB][10ms] = 8` → 128 个激励样本，而这一帧只有 120 个样本。多出来的 8 个是**编在比特流里的**（要照读），只是合成用不到。第一版在这里加了 `assert(samples == flength)`，fuzz 一跑就炸——参考实现根本没这个约束。
* **定点溢出在 Zig 里是 panic，在 C 里是回绕**：`silk_lsf2lpc` 的 `ROUND_MULL`、`pol[j] += …`、`nlsf[k] = …`（int16 截断）都依赖回绕。全部换成 `*%`/`+%`/`-%` 与 `@truncate` 之后，10000 轮变异 fuzz 才干净。
* **激励的符号概率是三维表**：`excitation_sign[active + voiced][qoffset_high][min(pulsecount, 6)]`。把 `active+voiced` 写成 `voiced` 时，pkt0（unvoiced）照样 145 dB，因为 unvoiced 的索引恰好也合法——只有 voiced 帧会错，而且错得"像那么回事"。
* **LTP 的再白化与 rescale**：`out_end` 与 `scale` 的分支（`i<2 || interp==4`）决定"从哪开始把输出反滤波成残差"和"用不用 LTP scale"；`out_end != 0` 时还要把上一子帧的残差按 `gain[i-1]/gain[i]` 缩放。少任何一半，增益突变的帧就会整体响度差 20%。
* **包尾的 ≥17 比特不是填充**：SILK 包尾若剩下 ≥17 比特，那段是 CELT 冗余帧（RFC 6716 §4.2.3 的模式切换用），要读一个方向位、按 `size − ceil(tell/8)` 切出它、解 5 ms CELT 再做 crossfade。把它当"剩余比特"跳过，`opus-48k-24-voip.opus` 的 SNR 会从 141.9 dB 掉到 **20.1 dB**——只有 240 个样本，但足够毁掉整条流。
* **立体声 SILK 是 mid/side，不是两路独立 SILK**（这一轮接上的）：`stereo_weights` 每帧三组预测权（RFC 6716 §4.2.2），L/R 由 `silk_stereo_MS_to_LR`（ffmpeg 的 `silk_unmix_ms`）还原：`L = (1+w1)·mid + side + w0·p0`、`R = (1-w1)·mid − side − w0·p0`，其中 `p0 = 0.25·(mid[i-2]+2·mid[i-1]+mid[i])`、前 `stereo_interp_len`（{64,96,128}）个样本用上一帧权重线性插值。**不要按"两路独立"实现**：那样 side 会和 mid 一起被当成两路信号，输出是噪声。`opus_silk.zig` 的 `unmixMs` 早就写好了，这一轮把它接进默认路径。


#### Hybrid：两层在同一帧

Hybrid（config 12–15）是 Opus 最后一块：**同一帧里 SILK 编低频带、CELT 编高频带**，解码器要把两路都解出来再相加 `src/opus_hybrid.zig`。它不是"先 SILK 后 CELT 的两个包"，也不是频域拼接——理解这一点，四个决定就都顺下来了：

1. **比特怎么分：没有长度字段，靠共享的范围解码器。** SILK 与 CELT 不是两段各自定长的字节区，而是**同一个算术编码器**：SILK 从前面消耗符号，CELT 从 SILK 停下的那个比特位置接着解。所以"切分点"就是 `rc.tell()`，一般**不在字节边界**上；CELT 的比特预算仍是**整帧**的比特数（不是剩下的尾巴）。实测：`opus-48k-24-voip.opus` 第 0 个 Hybrid 包 SILK 用掉 **578/744 bit**（CELT 起于第 578 bit，剩 166 bit）；`silk-20k-wb.opus` 第 0 个是 **543/672**（剩 129）；它结尾那个 10 ms Hybrid（config 13）是 **224/360**（剩 136）。
2. **唯一的字节对齐边界是包尾的冗余帧。** RFC 6716 §4.2.3：SILK 解完后若还剩 ≥17 bit（SILK-only 包）或 ≥37 bit（Hybrid 包，多一个标志位和长度字段的最小空间），后面可能挂一个 **5 ms 的 CELT 冗余帧**（模式切换用）。SILK-only 包只要剩 ≥17 bit 就**强制**有；Hybrid 包要先读一个 `logp=12` 的标志。切分点按 `ceil(tell/8)` 算，然后把范围解码器的可读区**缩短**（`shrink`）——这样 CELT 的 raw-bit 尾部和比特预算都止于冗余帧之前，和参考实现的 `dec.storage -= redundancy_bytes` 是同一件事。
3. **频带怎么分：CELT 从 band 17 起。** 起始频带固定 **17**（频带边界约 8 kHz），终止频带按包的带宽取 **19（SWB）/ 21（FB）**；CELT 侧只需要把 `start`/`end` 两个字段设对，其余比特分配、PVQ、IMDCT 全走原有代码。SILK 侧无论包标的是 SWB 还是 FB，**内部一律按 WB（16 kHz）** 合成，再用现成的重采样器升到 48 kHz。
4. **怎么合：时域相加。** 参考实现就是把 CELT 的输出**加**到 SILK 升采样后的缓冲上（ffmpeg 的 `vector_fmac_scalar`），本库同样 `out[i] = silk48[i] + celt[i]`。**对齐**是这里唯一的暗礁：SILK 重采样器有固定群延迟，每帧会少产几个样本并把余额带到下一次调用；参考实现每包只要"恰好一帧"的输出（`swr_convert` 的 `out_count = frame_duration`）并记 `delayed_samples`，本库照做——如果贪心地把重采样器攒下的 9 个样本一起吐出来，CELT 就会整体错位 9 个样本。实测错位 9 个样本时 `opus-48k-24-voip.opus` 是 **81.60 dB / 最大差 1.5e-3**：SNR 仍然"看着不错"，但 `max_diff` 的判据直接不通过——这就是为什么验收必须两条都看。少于一帧时直接 `error.Unsupported`，不"差不多对齐"。

**模式切换的 crossfade**：冗余帧解出来后，参考实现在**时域**做一个 2.5 ms 的交叉淡化，窗就是 CELT 的模式窗平方（libopus 的 `smooth_fade` 在调用点平方，ffmpeg 存成 `ff_celt_window2`；本库用 `window120_reference` 平方）。方向有两个且不对称：SILK→CELT 用冗余帧的**后半段**替换包尾（`fadeTail`），CELT→SILK 用**前半段**直接顶替再淡回主解码（`spliceHead`）。**这一段值多少 dB**：把 SILK 包的冗余分支关掉，`opus-48k-24-voip.opus` 从 **141.90 dB 掉到 20.05 dB**（最大差 0.133）——只有 240 个样本，但足够毁掉整条流。

**验收（对 `ffmpeg -f f32le` / `-f s16le`，判据同前）**：

| 素材 | 内容 | 帧数 | f32 SNR | f32 max | s16 SNR | s16 max |
| --- | --- | --- | --- | --- | --- | --- |
| `opus-48k-24-voip.opus` | 9 Hybrid + 11 SILK + 81 CELT，单声道 | 96000 | **141.90 dB** | 3.73e-08 | **105.85 dB** | 1 LSB |
| `silk-20k-wb.opus` | 9 Hybrid + 91 SILK + 1 个 10 ms Hybrid | 96000 | **145.36 dB** | 2.98e-08 | **106.06 dB** | 1 LSB |
| `opus-hybrid-mono-48k.opus`（入库 fixture） | 101 包全是 config 15（纯 Hybrid） | 96000 | **133.34 dB** | 1.34e-07 | **105.18 dB** | 1 LSB |

前两个文件的价值在于**三种包混在一条流里**都解对：Hybrid 打头、SILK 中段、CELT 收尾，任何一个模式的状态没接上，整文件 SNR 都会塌。第三个是入库的纯 Hybrid fixture，让没有外部语料库的 CI 也能测 Hybrid。`zig build bench` 的 Hybrid 行（2 s 单声道 32 kbps，101 包全 config 15）是 **535x 实时**（同一轮 SILK 1289x、CELT 272x），高于 100x 目标。

**Hybrid 的坑（按出现顺序）**：

* **CELT 的 `start` 是粘性状态**。Hybrid 把它设成 17；如果下一个 **CELT-only** 包没有显式设回 0，它就会继续从 band 17 解，`opus-48k-24-voip.opus` 的 SNR 直接掉到 **17.90 dB**（最大差 0.13）。这不是"声音闷一点"，是整帧比特分配错位。
* **离开 SILK 要 flush CELT**。参考实现在每个 SILK 包上 flush CELT（`ff_celt_flush`：重叠历史、后滤波、去加重、折叠种子、当前包络清零，两个历史包络置 −28 dB）。漏掉的话，`silk-20k-wb.opus` 末尾那个 Hybrid 包会带着 91 个 SILK 包之前的 CELT 历史解，SNR 从 **145.36 dB 掉到 114.58 dB**（最大差 1.4e-5）——仍然过 90 dB，所以这是一个"不报错、只变差"的 bug。
* **冗余帧的长度不是"剩下的字节"**。Hybrid 用 `decodeUint(256) + 2` 编码，SILK-only 用 `size − ceil(tell/8)`；两者都必须从 **SILK 解完那一刻**的 `tell()` 算，而不是读完方向位之后。差一个比特，切出来的 CELT 数据就整体偏。
* **`≥17` 与 `≥37` 不是拍脑袋**。SILK-only 的 17 = 1 个方向位 + 2 字节长度字段的最低空间；Hybrid 的 37 还要加上 `logp=12` 的标志位本身。把两者写成同一个常数，会在边界包上读出假冗余。
* **只解 SILK 半边也有 82.84 dB**。这是最危险的"看起来对"：丢掉的 CELT 高频带在 24 kbps VOIP 素材里能量不大，SNR 仍过 70 dB 的 s16 判据，但 f32 最大差 1.5e-3，离 1e-4 差一个数量级。所以 Hybrid 的验收必须看 `max_diff`，不能只看 SNR。



## 老格式与 Mac 来源：G.711 / ADPCM / AIFF

这一组格式的共同点是**整数运算、可逐样本校验**。六个 2 秒素材对 ffmpeg `-f s16le` 的 `max_diff` 全部为 0，样本总数完全一致：

| 素材 | 编码 | 样本数 | max_diff |
| --- | --- | --- | --- |
| `mulaw-8k.wav` | WAV µ-law 8 kHz 单声道 | 16000 | 0 |
| `alaw-8k.wav` | WAV A-law 8 kHz 单声道 | 16000 | 0 |
| `ima-wav-44k.wav` | WAV IMA ADPCM 44.1 kHz 单声道 | 89804 | 0 |
| `ms-adpcm-44k.wav` | WAV Microsoft ADPCM 44.1 kHz 单声道 | 89584 | 0 |
| `aiff-s16.aiff` | AIFF PCM16 44.1 kHz 单声道 | 88200 | 0 |
| `aiff-s24.aiff` | AIFF PCM24 44.1 kHz 单声道 | 88200 | 0 |

### G.711：表在 comptime 生成，不是抄来的常量表

`src/g711.zig` 的 256 项表由 G.711 分段压扩公式在编译期算出，源码里只有公式：

- µ-law：`u = ~code`，`mag = ((((u & 0x0F) << 1) + 33) << ((u >> 4) & 7)) - 33`，输出 `±4 * mag`；
- A-law：`a = code ^ 0x55`，`seg == 0 ? ((a & 0x0F) << 4) + 8 : (((a & 0x0F) << 4) + 0x108) << (seg - 1)`，符号位为 1 表示正。

两者都是 ITU-T G.711 的参考展开（与 Sun `g711.c` 的算术一致；µ-law 的 13 位幅度乘 4 进入 16 位范围）。测试用 256 个码的符号对称性 `table[code] == -table[code ^ 0x80]` 做全表校验，再对地标码做定点断言（µ-law `0x00 = -32124`、`0x80 = +32124`；A-law `0x2A = -32256`、`0xAA = +32256`）。

### ADPCM：有状态的块解码

- **IMA（tag 0x11）**：每声道 4 字节块头（`predictor: i16`、`step_index: u8`、reserved），数据按 8 个样本一组、每组内每声道 4 字节排列，**低 nibble 在前**。`diff = ((2 * (nibble & 7) + 1) * step) >> 3` 必须**先乘后移**：按参考实现逐项移位会分别截断，再经反馈环累积成几 LSB 的漂移。step index 钳位 0..88，predictor 饱和到 i16，每块独立重置状态。
- **MS（tag 0x02）**：每声道 7 字节块头，字段按声道交错写（所有 predictor → 所有 delta → 所有 sample1 → 所有 sample2）；输出先 `sample2` 再 `sample1`；nibble 高 4 位在前，且是**二进制补码**（-8..+7），不是 8 偏置。
- 块参数：MS 的 7 组预测系数**从 `fmt ` 扩展里读**（`cbSize = 32`），不写死；`block_align` 决定每块字节数，`samples_per_block` 由块大小推出（IMA `1 + (block-4ch)/(4ch)*8`，MS `2 + (block-7ch)*2/ch`），`total_frames = 块数 * samples_per_block`。ffmpeg 对 ADPCM 不按 `fact` 裁剪，最后一个块的填充样本照样输出，本库与之一致（所以 IMA 的样本数是 89804 而不是 `fact` 的 88200）。
- **MS ADPCM 最容易错的地方**：预测器是 `(sample1*coeff1 + sample2*coeff2) / 256` 的**向零截断除法**，不是 `>> 8`——负和时两者差 1。再叠加“nibble 用补码而不是偏置”和“sample1/sample2 的写入顺序”，任何一处错都会被反馈环放大成满量程误差。

### AIFF：80 位扩展浮点采样率

`src/aiff.zig` 读大端 `FORM`/`AIFF`：`COMM` 给声道数、帧数、位深和 80 位 IEEE 754 扩展格式的采样率；`SSND` 前 8 字节是 offset/block size，音频从 `8 + offset` 开始。PCM 8/16/24/32 大端，**8 位是有符号的**（与 WAV 的 128 偏置不同）。

80 位扩展的解析不是查表：值 = `mantissa * 2^(exponent - 16383 - 63)`，尾数带显式整数位。用 u128 做移位和就近舍入，因此 11025、37800、44056、192000 以及任何能放进 `u32` 的整数采样率都能解析；零、负数、NaN/Inf、次正规和超出 `u32` 的值分别有具名错误。

### 本轮明确拒绝

| 拒绝项 | 错误 | 原因 |
| --- | --- | --- |
| AIFC（压缩格式，也是 `fl32`/`fl64` 浮点 AIFF 的容器） | `error.Unsupported` | 需要额外的压缩类型字段，本轮不猜 |
| AIFF 20 位等非字节对齐 PCM | `error.Unsupported` | 只做 8/16/24/32 |
| AIFF `SSND` 在 `COMM` 之前 | `error.Unsupported` | 流式解码无法回退去重读采样 |
| WAV GSM 6.10（0x0031）、MP3-in-WAV（0x0055）等其它压缩 tag | `error.Unsupported` | 解码器不内置 |
| IMA / MS ADPCM 的 2/3/5 位变体 | `error.Unsupported` | 只做 WAV 的 4 位定义 |
| MS ADPCM 超过 2 声道 | `error.Unsupported` | ffmpeg 的 >2 声道布局是逐声道平面，本轮不做 |

### 测试、fuzz 与 bench

- `src/g711_test.zig` / `src/adpcm_test.zig` / `src/aiff_test.zig`：表地标与全表对称性、手算块（含 IMA 饱和、MS 截断除法与立体声交错）、AIFF 各位深与 80 位浮点边界、具名拒绝；
- `src/legacy_vectors_test.zig`：六个真文件的 `probe`/`Info`/`total_frames` 与 `max_diff 0` 验收（文件缺失时打印一行并 `SkipZigTest`）；
- `src/vorbis_huffman_test.zig` / `vorbis_floor_test.zig` / `vorbis_residue_test.zig` / `vorbis_dsp_test.zig`：规范里那张 8 码字示例表的逐码字回读、稀疏与单码字码本、截断/不可达码、trie 深码、X 列表整表排序（曲线形状回归）、`render_point` 整数插值、dB 表单调性、residue 三种格式的样本落点、IMDCT 对直接余弦和、四种窗形与重叠相加；
- `src/vorbis_decode_test.zig`：两个 Ogg/Vorbis 真文件**整文件**对 ffmpeg 的 f32 与 s16 输出，逐样本 SNR / 最大差 / 样本数，以及 `ShortBuffer` 与 granule 截断；
- `src/opus_test.zig` / `src/opus_vectors_test.zig`：`OpusHead` 各字段与 family 0/1、坏 magic/版本/零声道/坏 mapping 的具名错误、32 个 TOC config 与边界 0/11/12/15/16/31、`code 0/1/2/3`、1 字节与 2 字节帧长、1 字节与多字节 padding、120 ms 上限、1275 字节上限；五个真文件与 ffprobe 的 `duration_ts`/`channels`/`sample_rate` 对齐，并逐个包核对「帧大小 + framing + padding == 包长」；
- `src/opus_hybrid_vectors_test.zig`：Hybrid 的验收——两个混合素材与入库的纯 Hybrid fixture 整文件对 ffmpeg（f32/s16、样本数），两个素材的 config 直方图逐项钉死（防止某天素材悄悄少了 Hybrid 包还"通过"），10 ms Hybrid 收尾包单独测，以及"立体声 OpusHead + 单声道 Hybrid 包必须 `error.Unsupported`"（顺手把被改坏的首页 CRC 重算，因为容器层校验它）；`src/opus_hybrid.zig` 里另有窗表与两个 crossfade 方向的单元测试；
- 变异 fuzz 模板从 4 个扩到 12 个（六种老格式素材、Ogg/Vorbis 与 Ogg/Opus 全部在列；Ogg 模板真的走完整条解码链，Ogg-Opus 模板既走完整条解码链、又单独喂给 `opus.inspect`；Opus 模板现在有五个包：CELT、SILK WB 10 ms 双帧、**SILK NB 40 ms**、**Hybrid FB 20 ms** 与 **Hybrid SWB 10 ms**，让 SILK 的 8 kHz/两帧路径和 Hybrid 的共享范围解码器都吃到变异），`zig build fuzz` 10000 轮无 panic（本轮 619 万样本、1619 次 Opus 结构解析；SILK 定点路径的回绕/截断问题就是这一步逼出来的）；
- bench 共 14 行：本轮新增 **Opus 32k 单声道（Hybrid，两层同帧 + 时域相加）约 535x 实时**，Opus 12k 单声道（SILK 全链 + 重采样）约 1289x，Opus 128k 立体声（CELT 全链）约 272x，Ogg Vorbis q4 立体声约 470x，其余老格式行 4.8k–330k× 实时，均远高于 100x 目标；
- **永久回归语料** `src/fuzz_corpus/`：20 个最小化样本（Ogg lace/packet 5、Opus TOC 4、FLAC bit reader 3、AIFF 大端长度 4、ADPCM 块边界 4），每个都有 `corpus.json` 条目写明构造与**预期错误/阶段**；`src/fuzz_corpus_test.zig`（L1）逐样本断言错误名、出错阶段、输入长度上限、峰值分配 ≤ 同族有效基线、`deinit` 零泄漏。`src/fuzz_corpus_gen.zig` 可从结构化 builder 重新生成全部 `.bin`。反向证明：把任一 `expected_error` 改错一个名字，`zig build test` 必红；
- **分配/峰值/并发表**：`zig build bench` 在吞吐行之后按格式输出 `open_allocs / open_bytes / read_allocs / read_bytes / steady_allocs / peak_bytes / samples_per_sec`（构建模式 `ReleaseFast`、CPU 型号、输入 fixture、8192 i16 读缓冲、输出格式都打印在表头）。`read` 的 steady-state 分配实测为 0；Vorbis/Opus 的包前瞻只发生在首次 read（实测 1–3 次）。并发段同时打开 8 种解码器交错读，逐样本与单独解码完全一致，并报告并发峰值字节。

## 这不是 Zig 版 FFmpeg

这个库只做**一件事**：把一个已经拿到的音频字节流解码成交错 PCM。它不是多媒体框架，也永远不会长成 FFmpeg。

### 不做清单（以下这些**永不支持**）

| 不做 | 为什么永不支持 |
| --- | --- |
| 视频/图像解码 | 视频在 Windows / macOS / Linux 上都有系统解码器（Media Foundation + D3D11VA、VideoToolbox、VA-API），硬解、色彩管理和帧调度是平台强项；重写一遍只会更慢、更脆。 |
| 音频编码 / 转码 | 编码要码率控制、心理声学模型和大量格式组合，是另一条产品线；解码器的价值恰恰在于把这件事排除在外。 |
| 滤镜、重采样、混音图 | 这些是 DSP 策略，应该由调用方或专门的 DSP 库决定；解码器只负责把字节变成采样，不替调用方改变声音。 |
| 容器多路复用 / 解复用（MP4、MKV 的轨道、时间轴、编辑列表） | 本库只读**单个音频流的负载**，不选轨道、不建时间轴。唯一的例外是 Ogg：Vorbis 自身没有 framing，页、CRC 和 packet 边界只能由 Ogg 提供，所以 `src/ogg.zig` 只解析“第一个音频流”的页并校验 CRC，不做轨道选择，也没有编辑列表。MP4/MKV 仍在界外。 |
| 网络协议（HTTP、HLS、DASH、RTSP） | 网络、重试、缓存、鉴权都由调用方处理；库只接受一个 `std.Io.Reader`，不碰 socket，也不做请求。 |
| CLI / ffmpeg 命令行参数兼容 | 这不是命令行工具。目标 API 是 Zig 函数调用；模仿 `ffmpeg -i ... -af ...` 的参数方言与库的边界无关。 |

这些“永不支持”不是当前版本的偷懒，而是产品的边界：**边界越窄，流式、无分配、可 fuzz 才守得住。**

## 为什么只做音频

视频已经有系统解码器：Windows 的 Media Foundation + D3D11VA、macOS 的 VideoToolbox、Linux 的 VA-API 都能硬解，而且视频专利池复杂、格式迭代快。再写一个纯 Zig 视频解码器，投入产出比很差。

音频不一样：Windows 上 WASAPI 只负责**输出**，系统并不带 FLAC / Opus 解码器；macOS 的 AudioToolbox 对 FLAC 的支持也随版本和容器而变。一个应用如果想“走到哪都能放 FLAC”，最后往往还是得自带解码器。音频格式的专利面也窄得多（FLAC、Opus 都是开放、免专利的），维护成本比视频低一个数量级。

所以这里只做音频：**WAV 已完整（含 G.711 与两种 ADPCM），AIFF PCM 已支持，FLAC 子帧集合已完整**（官方 13 个向量全部整文件逐样本对齐），**Ogg Vorbis 已完整解码**，**Ogg Opus 的 CELT + SILK + Hybrid 三层都已能解码**（立体声 Hybrid/SILK 除外，见上）。

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
// header 至少 4 字节（FLAC/MP3 sync）或 12 字节（WAV）；Ogg 需要 36 字节才能看到首包魔数。
// 函数不读 reader，也不修改切片。
if (audio.probe(header)) |format| {
    // format == .wav、.flac、.mp3、.aiff、.ogg_vorbis 或 .ogg_opus
    // .ogg_opus 现在也能 open：纯 CELT 的流会真的出 PCM。
}
```

想在不解码的前提下看 Opus 的结构（这一轮新增）：

```zig
var reader = std.Io.Reader.fixed(bytes);
const info = try audio.opus.inspect(allocator, &reader, "");
// info.channels、info.pre_skip、info.total_frames（已是真实音频长度）、
// info.granule（= ffprobe 的 duration_ts）、info.packets、info.configs[0..31]
// 以及 info.sample_rate，恒为 48000。
// audio.opus.Decoder.open(...) 返回会解码的 Decoder；CELT/SILK/Hybrid 包都出 PCM，
// 3 帧以上的包与立体声 SILK/Hybrid 包在 read() 上返回 error.Unsupported。
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
| PCM µ-law（tag 7）/ A-law（tag 6） | ✅ | ITU-T G.711 表在 comptime 生成，展开为 16 位线性；`bits_per_sample` 报 16 |
| IMA ADPCM（tag 0x11） | ✅ | 每块独立重置 predictor/step index；8 样本一组、每声道 4 字节；`bits_per_sample` 报 16 |
| Microsoft ADPCM（tag 0x02） | ✅ | 预测系数从 `fmt ` 扩展读（不写死）；1–2 声道；`bits_per_sample` 报 16 |
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
| GSM 6.10（0x0031）、MP3-in-WAV（0x0055）等其它压缩 tag | `error.Unsupported` | 压缩/有损格式，解码器不内置 |
| IMA / MS ADPCM 的 2/3/5 位变体（`bits != 4`） | `error.Unsupported` | 只做 WAV 的 4 位定义 |
| MS ADPCM 超过 2 声道 | `error.Unsupported` | ffmpeg 对 >2 声道用逐声道平面布局，本轮不做 |
| MS ADPCM 系数表为 0 组 / 超过 16 组 / `cbSize` 不足 | `error.Corrupt` / `error.Unsupported` | 头部自相矛盾 / 工程上限 |
| PCM 12 / 20 位等非字节对齐位深 | `error.Unsupported` | 只支持 8/16/24/32 |
| IEEE float 64 位 | `error.Unsupported` | 只支持 float32 |
| `data` 在 `fmt ` 之前 | `error.Unsupported` | 流式解码无法回退去重读 `data`；不猜、不缓冲整个文件 |
| 超过 64 声道 | `error.Unsupported` | 明确的工程上限，避免帧大小失控 |
| PCM 的 `block_align` 与声道×位深不一致 | `error.Corrupt` | 头部自相矛盾 |
| PCM 的 `data` 长度不是整帧 | `error.Corrupt` | 半帧不是有效音频（ADPCM 允许最后一个块不完整，按实际字节数解码） |
| ADPCM 的 `block_align` 小于块头 / 数据短于一个块头 | `error.Corrupt` | 块布局自相矛盾，解码不了 |
| IMA 块头的 step index > 88、MS 块头的 predictor 越界 | `error.Corrupt` | 头部自相矛盾 |
| `fmt ` 长度 < 16、EXTENSIBLE 的 cbSize < 22、valid bits 越界 | `error.Corrupt` | 头部结构损坏 |
| 流在头部/数据中途结束 | `error.Truncated` | 不把截断当正常 EOF |
| 多个 `data` chunk | ⚠️ 只解第一个 | 流式解码在第一个 `data` 结束；后续数据忽略 |

### AIFF：完整支持

| AIFF 变体 | 状态 | 说明 |
| --- | --- | --- |
| `FORM`/`AIFF` 容器、`COMM` + `SSND` | ✅ | 大端；未知 chunk 按 AIFF 奇数长度 padding 跳过；重复 `COMM` 忽略后一个 |
| PCM 8 / 16 / 24 / 32 位 | ✅ | 全部大端；8 位是**有符号**的，与 WAV 的 128 偏置不同 |
| 任意整数采样率（80 位扩展浮点） | ✅ | u128 解析 `mantissa * 2^(exp - 16383 - 63)`，不查表；小数按就近舍入 |
| `COMM` 帧数声明 | ✅ | `Info.total_frames` 用声明值；`SSND` 实际字节更少时，读完前缀后返回 `error.Truncated` |
| `SSND` 的 offset 字段 | ✅ | 跳过 offset 字节再读采样 |
| `AIFC`（压缩格式，含 `fl32`/`fl64` 浮点） | `error.Unsupported` | 需要解析压缩类型字段，本轮不做 |
| AIFF 中的 ADPCM（AIFC 的 `ima4` 等） | `error.Unsupported` | 属于 AIFC 压缩类型，同上 |
| 20 位等非字节对齐 PCM | `error.Unsupported` | 只做 8/16/24/32 |
| 32 位浮点 AIFF（`fl32`/`fl64`） | `error.Unsupported` | 容器是 AIFC，本轮明确不做 |
| `SSND` 在 `COMM` 之前 | `error.Unsupported` | 流式解码无法回退去重读采样 |
| `COMM` < 18 字节、`SSND` < 8 字节、offset 越过 payload | `error.Corrupt` | 头部自相矛盾 |
| 流在 chunk 中途结束 | `error.Truncated` | 不把截断当正常 EOF |

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
| `RIFF` … `WAVE` | `.wav` | 尝试按 WAV 打开（PCM / float / EXTENSIBLE / G.711 / IMA / MS ADPCM） |
| `fLaC` | `.flac` | 尝试按 FLAC 打开（支持 CONSTANT / VERBATIM / FIXED / LPC + 三种去相关） |
| `FORM` … `AIFF` | `.aiff` | 尝试按 AIFF 打开（大端 PCM 8/16/24/32） |
| `FORM` … `AIFC` | `null` | `error.Unsupported` |
| `OggS` + 首包 `\x01vorbis`（需要 ≥ 36 字节才能看到首包魔数） | `.ogg_vorbis` | 解析 Ogg + Vorbis 头后返回可读 PCM 的 `Decoder` |
| `OggS` + 首包 `OpusHead`（同样需要 ≥ 36 字节） | `.ogg_opus` | 解析 Ogg + `OpusHead`/`OpusTags` 后返回 `Decoder`；CELT/SILK/Hybrid 包都出 PCM，3 帧以上的包与立体声 SILK/Hybrid 包在 `read()` 上 `error.Unsupported` |
| `OggS` + 其它/未知逻辑流 | `null` | `error.Unsupported` |
| `RF64` / `RIFX` + `WAVE` | `null` | `error.Unsupported` |
| 其他 | `null` | `error.NotAudio` |

`probe()` 宁可返回 `null` 也不把“看起来像”的东西当成可解码格式。`.ogg_opus` 是一个已识别、且**部分可解码**的格式：`probe` 如实报出容器与编码器，`open` 返回真正会解码的 `Decoder`，CELT/SILK/Hybrid 包都出 PCM，3 帧以上的包与立体声 SILK/Hybrid 包在 `read()` 上明确返回 `error.Unsupported`——打开成功不代表每条包都能解，因为包的编码模式写在包里。`open()` 也不接受 `probe()` 不会返回的格式。

## 公共 API

```zig
pub const Format = enum { wav, flac, mp3, aiff, ogg_vorbis, ogg_opus };

pub const Info = struct {
    format: Format,
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16, // 源位深：WAV 报容器位深（float 报 32，G.711/ADPCM 报 16）；
                          // FLAC 报真实位深 4..32；AIFF 报 COMM 的位数
    total_frames: ?u64,   // 头部声明；流式容器/未知总长时为 null
};

pub const Error = error{
    NotAudio,    // 不是本库认识的音频签名
    Unsupported, // 认识但不支持（FLAC 32 位 side 声道、AIFC、RIFX/RF64、GSM…）
    Truncated,   // 流在完整头部/帧之前结束
    Corrupt,     // 头部字段自相矛盾、CRC 不符或结构损坏
    OutOfMemory, // open 时分配失败（FLAC 分配一帧缓冲；WAV 的 ADPCM 分配一块）
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
- **调用方给缓冲**：`read()` 只在 `out` 里写，不分配；`open()` / `openBytes()` / `openFile*()` 是仅有的可能使用 allocator 的地方（WAV 的 PCM/float/G.711 不分配帧缓冲，ADPCM 分配一个压缩块和解码块；FLAC 按 STREAMINFO 的 max block size 分配一帧 i32 缓冲；两个便利入口还会分配 Reader 状态，`openFile*` 另加 64 KiB 读缓冲）。
- **`read()` 的容量**：能解 `out.len / info.channels` 帧。`out.len` 不是声道数的整数倍时，只解完整帧，尾部 i16 不碰；`out.len == 0` 返回 0；`0 < out.len < channels` 返回 `error.ShortBuffer`。
- **返回的是写入的 i16 个数**，一定是 `channels` 的整数倍；`0` 表示流结束。
- **前缀语义（FLAC / MP3 / Ogg Vorbis / Ogg Opus）**：如果某一帧/块/包失败（CRC、截断、32 位 side），此前已经解出的样本会先返回；下一次 `read()` 返回同一个错误。调用方既能拿到合法音频，也能看到具名失败，而不是被“半段静音”糊弄。WAV / AIFF 是**按调用全有或全无**：出错的那次调用不返回样本，前缀只来自更早的成功调用；两种规则都在下面的跨格式契约表里，并由矩阵测试逐格式断言。
- **声道原样保留**：不做下混、不做上混、不做采样率转换。5.1 就是 6 声道。
- **reader / 文件生命周期**：`open` 的 `reader` 由调用方持有；`openBytes` 的 `bytes` 不被复制；`openFile*` 的 `file` 不被关闭。三者都必须比 `Decoder` 活得久，`deinit()` 只释放 decoder 自己分配的东西。
- **错误后不复用**：`read()` 返回错误后，同一个错误会粘住（再次 `read()` 返回同一个具名错误，不会变成 0 或另一种错误），但 decoder 的状态不再保证可恢复，直接 `deinit()`；不要用“再读一次”来探测错误是否消失。
- **入口会消费流**：`open()` 读取 12 字节签名并扫描元数据/chunk，直到首个音频帧（WAV 是 `data` 负载，FLAC 是第一帧）起点；`openFile*` 用 positional reader 从 offset 0 开始；失败时也可能已经消费了最多 12 字节（甚至更多头部）。Ogg 的 `open()` 只读到三个 Vorbis 头包就返回流式 decoder；Opus 的 `opus.open()` 只读 `OpusHead`/`OpusTags` 两个头包就返回 decoder，两者的 `total_frames` 都要读到末页 granule 才知道，所以 `read()` 到 EOF 后才填上；`opus.inspect()` 则把结构视图交出来。想先判断而不消费，用 `probe()`（需要调用方自己准备那几字节；Ogg 要 36 字节）。
- **错误不吞**：截断、损坏、不支持、I/O 失败分别有具名错误；不使用 `catch {}` 把问题变成静音。

### 跨格式契约：短缓冲、前缀与错误映射

短缓冲矩阵（`src/stream_matrix_test.zig`，数据由 `src/stream_builders.zig` 在内存里构造，纯 L1）对**每一种** decoder 跑同一组调用方缓冲大小：满缓冲（对照组）、1 个 i16、3、7、13 个 i16、固定种子的随机 1..64 个 i16，以及“小缓冲/满缓冲交替”的混合序列。缓冲大小按 **i16 元素**算，不按帧算；解码器每次最多解 `out.len / channels` 帧。26 个变体（WAV PCM 8/16/24/32、float32、EXTENSIBLE PCM/float、µ-law、A-law、IMA ADPCM、MS ADPCM；AIFF 8/16/24/32；FLAC 8/12/16/24；MP3 单/立体声；Vorbis 单/立体声；Opus 单/立体声）× 7 种缓冲 = 182 个格子，断言：

- 拼接起来的所有样本与满缓冲解码**逐样本相等**：不重复、不丢失、不插入静音；
- 非帧对齐的尾部（`out[n..out.len]`，`n` 是实际写入数）**不被写**；测试先填哨兵值再检查；
- `out.len == 0` 返回 0 且不推进状态；EOF 之后重复 `read()` 返回 0，不返回错误；
- `0 < out.len < channels`（例如立体声 + 1 个 i16）返回 `ShortBuffer` 且**不消费任何样本**，随后换回大缓冲必须从原位置继续；
- `read()` 期间的单次分配 ≤ 512 B（上限写在测试里；实测：WAV/AIFF/FLAC/MP3 为 **0 B**，Vorbis 的包前瞻 `ArrayList` 最大 134 B，Opus 最大 204 B），且**总分配量与调用方缓冲大小无关**（逐变体对比满缓冲基线的字节总数）。`open()` 按 STREAMINFO 分配的一帧缓冲、Ogg 的 64 KiB 页缓冲都不算在内，它们在 `read()` 之前完成。

截断输入的行为（头部完整、音频负载被切掉 20 字节，切点落在最后一帧/页内部）：

| 格式 | 出错的那次 `read()` | 可解前缀 | 之后再次 `read()` |
| --- | --- | --- | --- |
| WAV PCM / G.711 | 返回 `error.Truncated`，该次调用不返回样本 | 只来自更早的调用 | 同一个 `Truncated` |
| WAV IMA / MS ADPCM | 返回 `error.Truncated`；同一次调用里已从上一块拷出的样本会被丢弃 | 只来自更早的调用（完整块） | 同一个 `Truncated` |
| AIFF | 返回 `error.Truncated`，该次调用不返回样本 | 只来自更早的调用 | 同一个 `Truncated` |
| FLAC | 先返回本次已解出的样本，错误挂起 | 是 | 同一个 `Truncated` |
| MP3 | 同上 | 是 | 同一个 `Truncated` |
| Ogg Vorbis | 同上 | 是 | 同一个 `Truncated` |
| Ogg Opus | 同上 | 是 | 同一个 `Truncated` |

所有行共同的断言：前缀是**未截断解码结果的精确前缀**，且严格短于它；不存在“补零到缓冲末尾”“返回 0 样本假装 EOF”或“前缀里混入静音”的行为。测试在 `src/stream_contract_test.zig`。

上面这套矩阵在 `src/fixtures_test.zig` 里还有一份**真实素材**版本（L2）：MP3 单/立体声、Vorbis、FLAC 24-bit、WAV 5.1 五个仓库内 440 Hz fixture × 同一组 7 种缓冲 = 35 格。原因是 L1 合成流里 MP3 mono 与 Vorbis 的样本本身是静音（没有真实编码内容），只靠长度无法发现“等长但值被交换”的错误；真实素材把这一格补成逐样本断言。

`open()` 的错误映射（每种格式 × 同一组坏输入；断言的是**错误类别**，不是“有错就行”，并且 `open` 成功 + 首个 `read` 静默返回 0 也算失败）：

| 输入 | WAV | AIFF | FLAC | MP3 | Vorbis | Opus |
| --- | --- | --- | --- | --- | --- | --- |
| 空流 | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` |
| 随机字节（magic 不匹配） | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` |
| 真头、截到 12 字节 | `Truncated` | `Truncated` | `Truncated` | `Truncated` | `Truncated` | `Truncated` |
| magic 被改坏 | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` | `NotAudio` |
| 底层 Reader 报 `ReadFailed` | `Io` | `Io` | `Io` | `Io` | `Io` | `Io` |
| 认识但拒绝 | `Unsupported`（RF64） | `Unsupported`（AIFC） | `open` 阶段无此类（见下） | `Unsupported`（MPEG-2） | `Unsupported`（未知 Ogg codec） | `Unsupported`（mapping family 2） |
| 结构损坏 | `Corrupt`（`fmt` 块对齐矛盾） | `Corrupt`（COMM 过短） | `Corrupt`（STREAMINFO 块大小为 0） | `Corrupt`（bitrate index 15） | `Corrupt`（页 CRC 不符） | `Corrupt`（OpusHead version 0） |

FLAC 唯一的 `Unsupported` 是**帧级**判定：32 位去相关流的 side 子帧会是 33 位，`open` 无法在不解一帧的情况下知道，所以 `open` 成功、`read` 返回 `error.Unsupported`（同一张契约测试里断言）。

### PCM 输出规则（逐比特可复现）

`read()` 只输出一种格式：**交错、帧优先的 i16**。第 `f` 帧第 `c` 声道在 `out[f * channels + c]`，一帧内声道顺序与源文件一致。

| 源格式 | 转换规则 | 说明 |
| --- | --- | --- |
| WAV 8-bit unsigned PCM | `(byte - 128) << 8` | 128 → 0，0 → -32768，255 → 32512 |
| WAV 16-bit PCM | 原样复制 | 逐位不变 |
| WAV 24-bit PCM | 算术右移 8 位（丢低 8 位） | 与 ffmpeg `-f s16le` 一致；不是四舍五入 |
| WAV 32-bit PCM | 算术右移 16 位（丢低 16 位） | 同上 |
| WAV float32 | clamp 到 [-1, 1]，NaN → 0，±inf → ±满量程；`round(x * 32768)`，`1.0` → 32767 | float 源的舍入不属于 WAV 格式，允许与其它实现差 1 LSB |
| WAV µ-law / A-law | 查表展开到 16 位 | ITU-T G.711 comptime 表，逐码精确；`bits_per_sample` 报 16 |
| WAV IMA / MS ADPCM | 块解码到 16 位 | 每块重置状态；`total_frames` 含末块填充样本，与 ffmpeg 一致 |
| AIFF 8-bit | `sample << 8`（**有符号**） | 与 FLAC 8 位相同，不是 WAV 的 128 偏置 |
| AIFF 16-bit | 原样复制（大端读取） | |
| AIFF 24-bit | 算术右移 8 位 | 取高 16 位 |
| AIFF 32-bit | 算术右移 16 位 | 取高 16 位 |
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
- **无分配（或显式 allocator）**：WAV 的 PCM / float / G.711 路径零分配；WAV 的 ADPCM 在 `open*()` 用调用方的 allocator 分配**一个压缩块 + 一个解码块**；FLAC 在 `open*()` 分配**一帧**的 i32 缓冲；`read()` 永远不分配；`deinit()` 释放。
- **显式错误**：`NotAudio` / `Unsupported` / `Truncated` / `Corrupt` / `Io` / `OutOfMemory` / `ShortBuffer`；没有“静音代替错误”。
- **可 fuzz**：解析器只接受 `[]const u8` 和 `std.Io.Reader`，没有文件系统、线程、时间依赖；`zig build fuzz` 对 12 种合法模板（WAV / FLAC / MP3 mono / MP3 stereo / µ-law / A-law / IMA ADPCM / MS ADPCM / AIFF16 / AIFF24 / Ogg-Vorbis / Ogg-Opus）做随机变异，断言不 panic、不越界、错误具名。

## 构建与测试

需要 **Zig 0.17.0**。零外部依赖、零 C、禁止 `@cImport`。

```sh
zig build            # 编译库（static lib 到 zig-out/）
zig build test       # 单元 + API + fixture + ffmpeg 集成 + 1000 轮变异 fuzz（12 种模板，329 个测试）
zig build fuzz       # 10000 轮变异 fuzz（WAV / FLAC / MP3 / G.711 / ADPCM / AIFF / Ogg-Vorbis / Ogg-Opus 共 12 种模板）
zig build bench      # 10 秒 WAV + 各 20 秒 FLAC（固定预测 / LPC）、MP3 与老格式解码基准（ReleaseFast；低于目标会失败）
```

### ffmpeg 配置与发布门

实时 ffmpeg 对照只存在于测试和对照工具中，公共库模块不依赖 ffmpeg。路径按以下**严格优先级**解析；高优先级一旦设置，即使路径错误也不会悄悄回退：

1. `ZA_FFMPEG_PATH`：可以是 ffmpeg 可执行文件的完整路径，也可以是包含它的 `bin` 目录；
2. 仓库根目录的 `ffmpeg.path`：单行路径，规则同上；此文件已加入 `.gitignore`，用于本机配置，不入库；
3. 原开发机默认路径：仅作为向后兼容的本机便利。

第一次调用会打印 `ffmpeg: source=env|file|default path=...`。找不到可执行文件时，每个受影响用例都会打印名称和 `ffmpeg_unavailable` 原因；ffmpeg 已启动但返回失败则是测试失败，不会伪装成 skip。

测试汇总分为四层：`L1` 纯库、`L2` 仓库内固定小样本、`L3` 外部向量结构/元数据对照、`L4` 实时 ffmpeg 对照。**凡需实时 ffmpeg 的外部向量逐样本用例也归入 L4**。每层打印 `executed=N compared=M skipped=...`；`compared` 是完成参考值/固定向量/ffmpeg 对照的测试数，不是样本数。

开发机默认仍允许 L4 skip，但发布门不允许：

```sh
# 新机器 / CI 的最小发布门命令（路径换成实际 exe 或 bin 目录）
ZA_FFMPEG_PATH=/path/to/ffmpeg zig build test -Drequire-ffmpeg=true

# PowerShell
$env:ZA_FFMPEG_PATH = 'C:\tools\ffmpeg\bin'
zig build test -Drequire-ffmpeg=true

# 也可用环境变量开启同一道门，不必重新编译选项
ZA_REQUIRE_FFMPEG=1 zig build test
```

`-Drequire-ffmpeg=true` 或 `ZA_REQUIRE_FFMPEG=1` 会把**任何 L4 skip 都提升为失败**，逐个打印用例名与原因；这包括 `external_vectors_missing`，所以发布环境还必须准备好下面列出的外部向量。测试运行步骤不重用上一次的环境结果，修改 `ZA_FFMPEG_PATH` 后不会因为构建缓存而沿用“全绿”。

仓库还提交了 **0.02 秒的 ffmpeg 生成音频样本**（`src/fixtures/`，总计约 200 KB）：没有 ffmpeg 的普通开发测试也能解码真实的 PCM8/16/24/32、float32、5.1 WAV，以及固定预测和 LPC（mono 8 kHz、stereo 44.1 kHz order 32 mid/side）的 FLAC；其中的 stereo LPC 文件还与其同源 WAV 逐样本一致。Opus 侧另有 2 秒 SILK 与 2 秒**纯 Hybrid** 素材。

- `tools/fetch-vectors.ps1`：把 13 个 [ietf-wg-cellar/flac-test-files](https://github.com/ietf-wg-cellar/flac-test-files) 官方向量下载到 `.zig-cache/vectors/`，逐个做 SHA-256 校验；向量不进 git。向量缺失时默认打印原因并 `SkipZigTest`；发布门会拒绝涉及 L4 对照的缺失。
- `src/compare.zig`：测试辅助。把本库解出的 i16 与 ffmpeg 的 `-f s16le`、`-f s32le >> 16` 逐样本比较，并支持“截断流的可解前缀”对比（60 号向量的 50% 截断用例）。
- `src/flac_build.zig`：测试专用的小型 FLAC 编码器，用来造 CONSTANT / VERBATIM / FIXED / LPC、各种位深、块大小扩展、wasted bits、escape code、LPC 精度/阶数/正负 shift，以及 L/S、R/S、M/S 三种去相关声道的精确用例；不参与库代码。
- `src/stream_builders.zig`：测试专用的全格式合成流（26 个变体，全部在内存里构造）；短缓冲矩阵与错误映射契约共用，不参与库代码。
- `src/stream_matrix_test.zig`：短缓冲矩阵（26 变体 × 6 种缓冲 = 156 格）与 `read()` 分配上限/独立性断言，纯 L1。
- `src/stream_contract_test.zig`：截断前缀语义与 `open()` 错误映射两张契约表，纯 L1。
- `src/legacy_vectors_test.zig`：G.711 / ADPCM / AIFF 六个 2 秒素材对 ffmpeg 的整文件逐样本验收；素材放在仓库外的 `..\zig-audio-vectors\legacy`，缺失时默认打印原因并 `SkipZigTest`，发布门下则失败。

### 目录

```
src/root.zig        公共 API（probe / open / openBytes / openFile / Decoder）
src/types.zig       公共类型（Format / Info / Error）
src/wav.zig         流式 WAV 解码器（PCM / float / G.711 / ADPCM 分派）
src/g711.zig        ITU-T G.711 µ-law/A-law 表（comptime 生成）
src/adpcm.zig       IMA / Microsoft ADPCM 块解码与 fmt 扩展解析
src/aiff.zig        流式 AIFF 解码器（大端 PCM + 80 位扩展采样率）
src/flac.zig        流式 FLAC 解码器
src/flac_bits.zig   MSB 位读取 + CRC-8 / CRC-16
src/flac_meta.zig   STREAMINFO 与元数据块循环
src/flac_frame.zig  帧头、子帧、Rice 分区、帧尾 CRC
src/flac_build.zig  测试专用 FLAC 编码器（不进库）
src/ogg.zig         Ogg 页、CRC-32、packet 拼装、首音频流选择
src/vorbis.zig      Vorbis identification / comment / setup（floor、residue、mapping、mode）
src/vorbis_bits.zig LSB-first 位读取 + ilog / lookup1_values
src/vorbis_codebook.zig  码本长度表与 VQ lookup（含 type 1 lattice）
src/opus.zig        Ogg Opus 入口（inspect 结构视图 / Decoder 流式解码，pre-skip 与 granule 裁剪）
src/opus_head.zig   OpusHead / OpusTags（RFC 7845）
src/opus_packet.zig TOC 与帧打包（RFC 6716 §3.2）：帧数、帧长、padding、每帧样本数
src/opus_range.zig  范围解码器（RFC 6716 §4.1）：符号、raw bits、tell/tellFrac、Laplace
src/opus_celt_tables.zig  CELT 常量表（48 kHz、21 频带）：Table 57、caps、窗、IMDCT/FFT 旋转因子
src/opus_celt_energy.zig  粗/细/最终能量反量化（§4.3.2）
src/opus_celt_alloc.zig   比特分配（§4.3.3）：预留、倾斜、两次二分、跳带、细能量分配
src/opus_celt_pvq.zig     PVQ（§4.3.4.2）：V(N,K)、cwrsi、扩散旋转、collapse mask
src/opus_celt_math.zig    比特精确的整数算术（bitexact_cos / isqrt32 / Q15 乘）+ folding LCG
src/opus_celt_bands.zig   theta、递归分裂、单声道频带解码（§4.3.4）
src/opus_celt_frame.zig   立体声重建与逐帧频带循环（§4.3.4.4、§4.3.8）
src/opus_celt_post.zig    anti-collapse 与反归一化（§4.3.5、§4.3.6）
src/opus_celt_dsp.zig     IMDCT（混合基 FFT）、重叠相加、音高后滤波、去加重（§4.3.7）
src/opus_celt.zig     一帧的符号顺序与状态（§4.3、Table 56）
src/opus_silk.zig    SILK 一帧的符号顺序与状态（§4.2）：帧头、LBRR、增益、LSF、音高、激励、再白化 + LTP + LPC 合成
src/opus_silk_lpc.zig  LSF→LPC：stage-2 反预测、稳定化、LSP→多项式→LPC、带宽扩展与稳定性检查
src/opus_silk_types.zig  SILK 的每声道状态（LSF/LPC/增益/lag/两段历史）与带宽定义
src/opus_silk_resample.zig  8/12/16 kHz → 48 kHz，复刻 libswresample 在该配置下的多相滤波、流式缓冲与结尾 flush（镜像补尾）
src/opus_silk_tables_cdf.zig      SILK 的算术模型（RFC 6716 §4.2 的 35 张 CDF 表）
src/opus_silk_tables_lsf.zig      LSF 码本、权重、排序、cos 表
src/opus_silk_tables_pitch.zig    音高/LTP/激励/立体声表
src/opus_hybrid.zig  Hybrid 与 SILK 包：共享范围解码器、SILK→48 kHz 对齐、SILK+CELT 逐声道时域相加、冗余帧 crossfade、立体声（mid/side + 每声道重采样）
src/ogg_build.zig / vorbis_build.zig / opus_build.zig  测试专用 Ogg 页 / Vorbis 头 / Opus 头与包的写入器（不进库）
src/stream_builders.zig / stream_matrix_test.zig / stream_contract_test.zig  全格式合成流 + 短缓冲矩阵 + 错误/前缀契约（不进库）
src/bench.zig       WAV + FLAC + MP3 + Ogg + 老格式基准程序
src/fuzz.zig        变异 fuzzer（同时作为 1000 轮测试运行）
src/compare.zig     与 ffmpeg 逐样本比较的测试辅助
src/ffmpeg.zig      测试专用 ffmpeg 路径解析、来源审计与进程入口
src/test_audit.zig  测试分层、skip 原因与 L4 静态归类
src/test_runner.zig L1-L4 汇总和 require-ffmpeg 发布门
src/fixtures/       提交进仓库的小样本 + 生成命令
src/*_test.zig      单元 / API / fixture / ffmpeg 集成测试
tools/              官方 FLAC 测试向量下载脚本
```

## License

MIT，见 [LICENSE](LICENSE)。作者：TLBtianhu。
