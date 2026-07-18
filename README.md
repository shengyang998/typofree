# TypoFree — LLM 纠错的小鹤双拼 macOS 输入法

macOS 中文双拼输入法(默认小鹤双拼),**候选 1 = 本地 LLM 结合聚焦窗口上下文修完错别字的整句**,其余候选与常规输入法一致。目标机器:8GB Apple Silicon MacBook,全程本地推理、零遥测。

## 核心设计

- **候选 #1 异步升级**:确定性引擎(词格 + unigram Viterbi)先出即时候选;本地 LLM(MLX Qwen,FoundationModels 可用时自动切换)拿「上文 + 拼音 + 引擎最优句」做同音错别字修正,100ms–2s 后异步回填槽位 #1,打字永不阻塞。
- **确定性校验门是特性成立的前提**:LLM 输出必须通过 re-pinyinize(逐字回转拼音须匹配原输入,多音字取任一读音)+ 长度 ±1 检查才能上屏;越界改写一律静默回落引擎结果。实测 bake-off 见 `research/prompt_bakeoff/RESULTS.md`。
- **学习词典**:检测「发送」(聚焦文本框清空)时对比输入法提交内容与最终内容,拼音对齐 diff 学习用户改字(occurrence≥2 才影响排序);SQLite 本地存储,一键清除。
- **隐私**:全本地、密码框双重硬禁用(`IsSecureEventInputEnabled` + AX subrole)、学习只存 ≤20 字短 span、零上传。

## 当前状态(2026-07-18)

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0-M4 | SPM 双包:小鹤方案表/双向解码、TFX1 词库(43.7 万词,OpenCC 简体化)、Viterbi 引擎(0.56ms/20 音节)、LLM provider + 校验门 + 异步 coordinator | ✅ |
| M5 | app shell:IMK controller、自绘候选窗(槽 1 异步)、安装脚本 | ✅ |
| M6 | 上下文三级降级(IMK→AX→仅本句)、密码框双守门、大写临时英文 | ✅ |
| M7 | 学习闭环端到端:Myers diff 学习器、sqlite 用户词典(occurrence≥2)、发送轮询、boost 进引擎排序 | ✅ |
| M8 | 设置页/引导/模型下载 UX、RAM 感知双模型预设、后端热切换 | ✅ |
| M8.5 | bundle id `.inputmethod.` 枚举修复(注册即出现,免登出) | ✅ 246 tests |
| M9-M10 | 真机验收(GPU 推理/FM 限流/AX TCC 三 spike)、Developer ID 签名公证 | ⏳ 待做 |

尚未到日常可用状态;架构与阶段性结论见 `DESIGN.md`、`research/`。

## 结构

```
TypoFreeCore/    纯 Swift SPM 包:方案/解码/词库/引擎/LLM 协议/学习 diff(零 AppKit 依赖,swift test 可测)
TypoFreeLLM/     MLX 集成包:Qwen runner、模型下载、backend resolver(依赖 Metal)
TypoFree/        app shell:IMKServer、InputController、候选窗、设置
tools/           词库构建(uv + Python):essay + phrase-pinyin + pinyin → TFX1 blob + TFXR 多音字侧车
data/            编译产物词库(8.6MB)与来源说明
research/        可行性研究、锁定决策、模型/prompt bake-off(可复现脚本)
```

## 构建与本机安装

```bash
cd TypoFreeCore && swift test          # 纯逻辑层
bash scripts/dev.sh                    # 构建 → 签名 → 安装到 ~/Library/Input Methods → 注册
```

安装后**立即**可在 系统设置 ▸ 键盘 ▸ 输入法 ▸ + ▸ 简体中文 里添加 TypoFree(bundle id 含 `.inputmethod.`,注册即被系统枚举,无需登出)。后续迭代重跑 `dev.sh` 即热替换。建议先跑 `scripts/make-dev-cert.sh` 生成稳定签名身份(否则每次重签会重置 TCC 授权)。

## 词库与 License

词库由构建脚本从三个开源数据源编译(`tools/build_lexicon.py`,可完整重建):

- [rime-essay](https://github.com/rime/rime-essay)(LGPL-3.0)— 词频;bundle 编译产物 + 保持重建脚本开放以符合其精神
- [phrase-pinyin-data](https://github.com/mozillazg/phrase-pinyin-data) / [pinyin-data](https://github.com/mozillazg/pinyin-data)(MIT)— 词/字拼音
- OpenCC(Apache-2.0)— 构建期繁→简

依赖:[vChewing/IMKSwift](https://github.com/vChewing/IMKSwift)(MIT)、[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)(MIT)。参考过 vChewing/Fire/Squirrel 等真实 IME 的公开实现模式(未复制 GPL 代码)。

本仓库自身的 License 待定。
