# 永久 fuzz 回归语料

这里放的是**最小化、可复现、带预期错误**的损坏音频样本。随机变异 fuzz 依赖种子，
种子只能证明"这一轮没炸"；语料证明的是"这个边界的行为不会被悄悄改掉"。

## 目录

- `*.bin`：最小化样本本身，测试用 `@embedFile` 编进二进制，不读文件系统；
- `corpus.json`：每个样本的机器可读说明：族、来源、构造方式、**预期错误**、
  出错阶段（`open` / `read`）、输入长度、曾出现的症状；
- 生成器：`src/fuzz_corpus_gen.zig`，`zig run src/fuzz_corpus_gen.zig`
  可从结构化 builder 重新生成全部 `.bin`，并打印每个样本的真实结果；
- 回归测试：`src/fuzz_corpus_test.zig`，归 L1，由 `zig build test` 执行。

## 五类结构化边界

| 族 | 边界 | 样本数 |
| --- | --- | --- |
| `ogg` | Ogg lace / packet 边界、页 CRC、页序列、跨页续包、EOF 半包 | 5 |
| `opus_toc` | Opus TOC 帧计数码、CBR 奇偶、零帧、120 ms 上限 | 4 |
| `flac_bits` | FLAC bit reader 的 EOF、帧头截断、wasted-bits unary 上限 | 3 |
| `aiff` | AIFF 大端长度、80 位扩展采样率、COMM/SSND 顺序与帧数 | 4 |
| `adpcm` | IMA/MS 块头、step/predictor 索引、短尾块、block_align | 4 |

每个样本都必须命中 `corpus.json` 里写明的错误名，且错误必须发生在写明的阶段。
"能打开但读的时候变成静音"不算通过：这些样本全部以具名错误结束。

## 每个样本断言什么

`src/fuzz_corpus_test.zig` 对每个样本跑一次完整解码流程，除了"不 panic"还断言：

1. **错误名与阶段**：`open` 类样本必须让 `root.open` 返回预期错误；`read` 类
   样本必须让 `root.open` 成功，并在第一次失败的 `read` 返回预期错误；
2. **输入长度上限**：样本长度为 `input_bytes`，计数器 reader 实际拉取的字节数
   不得超过它，reader 调用次数有上限（不会无限读）；
3. **内存上限**：用计数器 allocator 测 `open` 与 `read` 的分配次数、字节数和
   峰值；峰值不得超过同族**有效基线文件**（正常解码到 EOF）的峰值；`read`
   期间的分配次数也不得超过基线；
4. **deinit 平衡**：`deinit` 后未释放字节数和未释放块数都必须为 0，外层再用
   `std.testing.allocator` 复查泄漏/重复释放。

基线文件在测试内用现有 builder 构造，不占用语料目录。因此"内存 ≤ 基线"比较的
是**同格式正常文件**，不是拍脑袋的常数。

## 反向证明

把 `corpus.json` 中任一 `expected_error` 改错一个名字（例如 `Truncated` 改成
`Corrupt`），`zig build test` 必须变红；改回来必须变绿。这条验证的是语料断言
真的在比较错误名，而不是只检查"有错误"。

## 新增样本的流程

1. 在 `src/fuzz_corpus_gen.zig` 里用结构化 builder 构造最小字节；
2. 运行生成器，确认它打印出的 `stage:error` 就是你想要的；
3. 在 `corpus.json` 里写清来源、构造、预期错误和阶段，`input_bytes` 与文件长度一致；
4. `zig build test` 必须通过；如果没有通过，先判断是样本构造错了还是解码器行为
   真的变了，不要改预期错误去迁就实现。
