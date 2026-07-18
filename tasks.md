# TypoFree — 实现里程碑清单 (tasks.md)

> 依据 `DESIGN.md`。每个里程碑独立可构建 + 可验证 + 可提交（plan-act-test loop）。
> `[Core]` = 纯 TypoFreeCore/TypoFreeLLM，可 `swift test` 由隔离 agent 独立构建，无需 app shell/真机。
> `[Shell]` = 需 app-shell 接线 / 登录会话 / 真机测试。
> 工程评审 12 条 `must_fix` 已折进对应里程碑（标 **MF#n**）。

---

## M0 — 脚手架 `[Core]` (parallelizable)
- [x] 建两个 SPM 包目录 + `Package.swift`：`TypoFreeCore`（零依赖 + `CSQLite` system-library shim）、`TypoFreeLLM`（path dep Core + 钉 `mlx-swift-lm 2.31.3` + `swift-transformers 1.2.0`）。**MF#9**（统一目录根 `labs/typofree/TypoFreeCore`、`TypoFreeLLM`、`TypoFree.xcodeproj`、`TypoFree/`）— swift-tools-version 用 **6.2**（非 DESIGN 原文 6.1）,见下方 deviation 记录
- [x] `CSQLite/module.modulemap` + `shim.h`（`#include <sqlite3.h>`, `link "sqlite3"`）— 已用 `@testable import` 单测实链（`sqlite3_libversion()`）,证真 link 不只是 header 解析
- [x] 符号链接 `Resources/lexicon.bin` → `../../../../data/lexicon.bin`（`readings.bin` 待 M2 产出后补链）— **方向已反转**（见下方 deviation 记录）：真实字节现在落在 `TypoFreeCore/Sources/TypoFreeCore/Resources/lexicon.bin`,`data/lexicon.bin` 反过来是指向它的符号链接
- [x] 占位 `SchemeDefinition` + `NullProvider` + `Fixtures/mini-lexicon.bin`（手写小 TFX1）打通 `swift test`
- **交付**：`cd TypoFreeCore && swift test` 绿（占位）。**验证**：CI 无网络跑通。**依赖**：无。
- **交付确认 2026-07-18**：`TypoFreeCore`: `swift test` 7/7 绿（含新增的 CSQLite 实链测试 + lexicon.bin 真读取测试）。`TypoFreeLLM`: `swift build` 绿,`mlx-swift-lm` 精确钉住 `2.31.3`(无需降级),`swift-transformers` 解出 `1.2.1`(`.upToNextMinor(from:"1.2.0")` 语义内)。
- **M0 deviation 1（技术性,非设计决策）**：`swift-tools-version` 从 DESIGN.md §1 原文 `6.1` 改为 `6.2`。`platforms: [.macOS(.v26)]` 的 `.v26` 常量在本机 toolchain(Xcode 26.4 / Swift 6.3)上要求 PackageDescription **6.2**（`6.1` 编译期报 `'v26' is unavailable`,note 明确指向 6.2）。两个包都已改。
- **M0 deviation 2（发现 + 修复的 correctness bug，非设计决策）**：`Resources/lexicon.bin` 若按 DESIGN.md §1 原文那样做「从 Resources 指向 data 的相对符号链接」，在 `swift build`/`swift test` 下**会产出一个死链接**——SwiftPM 的资源拷贝把符号链接按原相对目标字符串原样复制（不是解引用复制字节），而 `.build/<triple>/<config>/*.bundle/` 的嵌套深度和源码树不一样，同一个 `../../../../` 在新位置解不到 `data/`（`realpath`/`head` 实测复现 `No such file or directory`，`swift build` 却报 success——纯从 log 看不出问题）。修法：**反转方向**——真实字节移到 `TypoFreeCore/Sources/TypoFreeCore/Resources/lexicon.bin`（git 正常追踪的二进制文件，任何拷贝机制、任何嵌套深度都能正常工作，M5 塞进 Xcode app target 后同理不会碎），`data/lexicon.bin` 变成指向它的符号链接（`data/lexicon.bin -> ../TypoFreeCore/Sources/TypoFreeCore/Resources/lexicon.bin`）。`build_lexicon.py` 的 `--out-bin` 默认值不用改——`Path.open("wb")` 写入时会跟随符号链接，重新跑 build 脚本会直接把新字节写进真实文件。新增 `LexiconResourceCheck`(Core, internal) + `LexiconResourceCheckTests`(`@testable import`) 通过 `Bundle.module` 真实读取资源字节回归锁定这个修复。详见 `data/README.md` 顶部的对应说明。
- **M0 发现（给 M4 的重要提示，非 deviation——Package.swift 依赖声明本身完全照抄 DESIGN.md 没改）**：`swift-transformers 1.2.1` 的 `Transformers` 是**纯 product 级聚合**（`Package.swift`: `.library(name: "Transformers", targets: ["Tokenizers", "Generation", "Models"])`），**不是可 import 的模块**——`import Transformers` 会报 `error: no such module 'Transformers'`。真正能 import 的是 `Tokenizers` / `Generation` / `Models`（以及独立的 `Hub`）。M4 写 `MLXQwenRunner`/tokenizer 相关代码时用 `import Tokenizers` 等具体子模块，`.product(name: "Transformers", package: "swift-transformers")` 这条 target 依赖声明本身留着不用动（它确实把三个子 target 都链进来了，只是没有同名 umbrella 模块）。

## M1 — Scheme + Decoder `[Core]` (parallelizable, dep M0)
- [x] `InitialClass`(5 类) + `SchemeDefinition`(`schemeId:UInt16=1`) + `FlypyScheme.flypy`（全部 Appendix A：21 声母键、`v/i/u→zh/ch/sh`、joint `finalTable`、35 条零声母表）。**MF#5**（统一为一套 Scheme/Decoder，`schemeId` == TFX1 header）
- [x] `ShuangpinDecoder.decode/decodeSyllable/encode(syllable:)/encode(tonelessSyllables:)`（正反向，init 内反演反向表 + precondition 单射校验）
- [x] 测试：**8 陷阱**(wai→wd…yong→ys) + 常规对照(yu/yuan/yue/yun/wu/aa/er) + 重载键(o/k/l/s/x/v/t) + r=uan/n=iao 条件例外 + 压缩声母 + 非法组合→nil + 反向 encode 往返(你好→nihc、世界→uijp) + 单实例(不受第二 scheme 影响)
- **交付**：decoder 全测过。**验证**：`swift test --filter Scheme`。**依赖**：M0。
- **交付确认 2026-07-18**：`Scheme/{SchemeDefinition,FlypyScheme,ShuangpinDecoder}.swift` 三文件落地；占位 `SchemeDefinitionPlaceholderTests.swift` 已删，换成 `Tests/TypoFreeCoreTests/SchemeDecoderTests.swift`（7 个 `Scheme*` 测试类）。`swift test --filter Scheme` 21/21 绿；全量 `swift test` 26/26 绿（M0 剩 5 个 + M1 新增 21 个；删掉的是 2 个占位 `SchemeDefinition` 测试）；`rm -rf .build` 净构建零 warning 零 error。`Syllable`/`DecodeResult` 放在 `Scheme/ShuangpinDecoder.swift`（DESIGN §1 文件树名义上把 `Syllable` 挂 Engine/，但 §2.1 与 decoder 同段定义、M1 owns，模块级类型不影响 import；M3 直接消费，可留可搬）。
- **M1 决策记录（Appendix A 散文 vs rime 真源）**：`finalTable` 按 DESIGN §2.1 强制的 5 类 `InitialClass` 建，数据取自 rime `double_pinyin_flypy.schema.yaml` 的 speller.algebra + translator.preedit_format（Appendix A 自称「逐条模拟 speller.algebra 解码」的真源）。原因：Appendix A 的重载键散文表是有损摘要——(a) 漏了 `dt+s / nl+s → ong`，但 东(ds)/通(ts)/农(ns)/龙(ls) 必须能打；(b) 把 k/l/x 的 A 侧窄化成 {g,k,h,zh,ch,sh}、排除 r/z/c/s，而 5 类模型无法把 r/z/c/s 从 `gkhzh` 里拆出来，rime 本身也是全 `gkhzh` 统一映射（`[gkhvuirzcs]k→uai` 等）。故本实现按 rime：每类内每个第二键解析为唯一 final，类内一致（已逐条验证）。唯一可见效应=非词组合如 `zk` 解成非词拼音 `zuai` 而非 nil（无害，词库永不含）。所有 M1 测试用的都是 rime 与 Appendix A 一致的真实音节。

## M2 — 词库加载 + 多音字侧车 `[Core]` (dep M1)
- [x] `LexiconBlobFormat`（**TFX1** 16B header、`loadUnaligned` 多字节、posting `wordLen→word→logFreq`、`logFreq=ln(1+rawCount)`）。**MF#1**（删 engine 原 `TFLX`，全线用 TFX1）
- [x] `LexiconStore.loadBundled/init(data:)/postings(forKey:)/maxSyllables`
- [x] **`build_lexicon.py` 增补 `readings.bin`（TFXR v1）**：`pinyin.txt` 每单字**全部**无调读音编成 `[Character:[String]]`。**MF#2**（D12 门必须的多音字数据源；否则 false-reject 的/地/得）
- [x] **`build_lexicon.py` 加构建期 OpenCC 繁→简**（user-Q1 已拍板，从 M9 提前）：opencc-python-reimplemented，同形合并频次，重跑产纯简体 `lexicon.bin`；重验 你好→nihc + 8 零声母陷阱 + `postings("aa")` 期望值改为简体序
- [x] `PinyinReadingIndex.loadBundled/readings(of:)/canRead(_:asShuangpinCodes:decoder:)/isAllHanzi`（接受任一读音，多音字安全）
- [x] 补 `readings.bin` 符号链接 + `Package.swift` resources
- [x] 测试：真 `lexicon.bin` 载入(`postings("aa")==[啊,阿,錒,嗄,锕]` 顺序 + 载入时间预算) + bad magic/version/truncated 抛错 + fixture 往返 + `readings.bin` 多音字覆盖(行→[xk,hh]、得→[de,dei])
- **交付**：真 blob + 侧车端到端载入。**验证**：`swift test --filter Lexicon`。**依赖**：M1。
- **交付确认 2026-07-18**：`Lexicon/{LexiconPosting,LexiconBlobFormat,LexiconStore,PinyinReadingIndex}.swift` 落地（+ 内部 `TFXRBlobFormat` 私有 reader，同文件）。`swift test --filter Lexicon` 33/33 绿；全量 `swift test`（`rm -rf .build` 净构建）56/56 绿、零 warning；`TypoFreeLLM` 侧 `swift build`+`swift test` 同步验证仍绿（1/1）。`build_lexicon.py` 全量重跑（`uv run build_lexicon.py`，6.81s）：essay 442,693→437,796 词（OpenCC 合并 4,897 条），resolved 437,490/437,796=99.9301%，`lexicon.bin` 310,654 keys / 437,490 postings / 9,044,402 bytes(8.63MB，比 OpenCC 前 8.67MB 略小)；`readings.bin` 44,435 字、6,992 个多音字（去调后去重；8,624 是去重前按调号区分的旧口径）、455,794 bytes(445.1KB)，最多 8 个读音/字（擖）。**`postings("aa")` 重算后的真实简体序 = `[啊,阿,锕,嗄]`**（4 项，非 DESIGN 引用的旧 5 项 `[啊,阿,錒,嗄,锕]`——繁体錒→简体锕，频次合并）。两次全默认参数重跑 md5 校验字节完全一致（确定性保持）。详细 rationale 见 `data/README.md`（新增 "OpenCC 繁→简 conversion" + "readings.bin toneless convention" 两节）。

## M3 — Lattice + Viterbi + user-boost overlay `[Core]` (dep M2)
- [x] `WordSpan`/`Candidate`/`EngineResult`(超集：engineBest+bestPath+focusCandidates+preeditDisplay+hanziCount+endsAtClauseBoundary+incompleteTail)。**MF#5**（统一结果类型）
- [x] `UserBoostOverlay`(不可变 snapshot, 加性 delta) + `LatticeConfig`
- [x] `Lattice` + `ConversionEngine.convert(_:overlay:focus:)`（每键全量重算、length bonus、兜底连通、tie-break 确定）。**MF#8**（overlay 必进 recompute，否则学习 inert）
- [x] `CandidateEngine` wire 协议带 `overlay` 参数。**MF#3**（修 overlay 到不了 lattice 的漏洞）
- [x] `EngineResult.preeditDisplay` 按 hybrid 默认产（见 user-Q3）
- [x] 测试：短语胜单字 / 稀有短语让位 / tie-break 确定 / 非法音节兜底 / **overlay 加性 boost 改排名回归**
- **交付**：确定性引擎全测过。**验证**：`swift test --filter Engine`。**依赖**：M2。
- **交付确认 2026-07-18**：`Engine/{Candidate,Lattice,ConversionEngine}.swift` + `Overlay/UserBoostOverlay.swift` + `Wire/CandidateEngine.swift` 落地（`Syllable`/`DecodeResult` 仍在 M1 的 `Scheme/ShuangpinDecoder.swift`）。`swift test --filter Engine` 19/19 绿（含强制的 overlay 改排名回归 + 感知性能测试）；全量 `swift test`（`rm -rf .build` 净构建）75/75 绿、零 warning（M0-M2 的 56 + M3 新增 19）；`TypoFreeLLM` 增量 `swift build` 仍绿（重编改动的 Core path dep + 重链，4.57s）。**性能**：真 `lexicon.bin` 上 20 音节 `convert` = **0.5572 ms/次**（50 次均值，远低于 5ms 目标；断言留 50ms 防 CI 抖动）。
- **M3 决策记录（DESIGN 未锁死处，非偏离）**：(1) **兜底边 word** = `syllable.pinyin ?? syllable.code`——合法但无词的音节显可读拼音（"nj"→"nan"），非法组合（"br"，`r` 不在 bpmf final 表→decode nil）显原始击键（"br"）。(2) **overlay-only OOV 词**（base 无该词）按 base logFreq=0 + delta 计分，与 base 词加性叠加同源，故用户学的词二次出现即可竞争排名。(3) **`hanziCount`** = 非 fallback span 的 word 字符数之和（base/overlay 词库均为纯汉字，只有 fallback 是拼音/字母，故等价于"engineBest 里的汉字数"，无需 Unicode 汉字判定）。(4) **`endsAtClauseBoundary`** = `engineBest.last ∈ config.clauseBoundary`；当前 a-z-only 击键缓冲下实际恒为 false（标点如何进组合由 M5 定），此字段是前向 hook。(5) **`engineBest` 不含 incompleteTail**（整句 Viterbi 只覆盖完整音节；hybrid preedit 才拼上尾字母）。

## M4 — LLM providers + 校验门 + coordinator `[Core]`+`[LLM]` (dep M3)
- [x] 唯一 `LLMCorrectionProvider` 协议 + `CorrectionRequest`/`CorrectionResult`(RAW) + `NullProvider`(返回 nil)。**MF#3**（四协议收敛：nil=放弃、provider 产 RAW、门在 coordinator）
- [x] `CorrectionValidator`(D12：全汉字→长度±1→`canRead` 任一读音命中率，比较空间=codes)
- [x] `CorrectionCoordinator`(actor, Core)：防抖/取消/触发门/emit==最新 requestID。**MF#4**（唯一异步编排，staleness=requestID）
- [x] `CorrectionPromptBuilder`(systemInstructions byte-identical + few-shot)
- [x] `FoundationModelsCorrectionProvider`(Core, `#if canImport(FoundationModels)`, @Generable + timeout race)
- [x] `CorrectionModelRunner` 端口 + `MLXQwenRunner`(Qwen3-0.6B-4bit, enable_thinking:false, temp 0) + `MLXCorrectionProvider`(actor, 状态机/按需载/闲卸双保险) + `TypoFreeModelDownloader`(HF→hf-mirror, App Support 缓存) [LLM]
- [x] `MLXModelManager` + `LLMProviderFactory` + `LLMBackendResolver`(FM→MLX→Null) [LLM]
- [x] provider 隔离硬契约断言：`correct()` 期间不占 MainActor（并发风险 #2）
- [x] 测试 [Core]：门 5 例(接受同音/拒 latin/拒长度/拒幻觉/**多音字不误拒**) + coordinator(防抖单次/clause 跳防抖/新键取消/stale-drop by requestID/超时→nil/卡死不死锁) 全用 `FakeModelRunner`+fake provider
- [x] 测试 [LLM]：`LLMBackendResolver` fake 两分支零网络；`MLXModelManagerLiveTests` 门控 `TYPOFREE_MLX_LIVE_TEST=1`(真下载+`additionalContext["enable_thinking"]==false`+无`<think>`)
- **交付**：整个异步修正状态机零 Metal 可测；MLX 真路径集成测试可选跑。**验证**：`swift test`(Core+LLM) + `TYPOFREE_MLX_LIVE_TEST=1 swift test`(dev box)。**依赖**：M3。
- **交付确认 2026-07-18**：`TypoFreeCore` `swift test`（`rm -rf .build` 净构建）**107/107 绿**（M0-M3 的 75 + M4 新增 32），零 warning。`TypoFreeLLM` `swift test` **18/18 绿**（17 跑 + 1 门控 live skip），零 warning（MLX/HubApi 的 `CoreData: NSXPCConnection failed` 是 sandbox 噪声非失败）。新增文件：Core `LLM/{CorrectionTypes,LLMCorrectionProvider,CorrectionValidator,CorrectionPromptBuilder,CorrectionCoordinator,FoundationModelsProvider}.swift`（+重写 `NullProvider.swift`）；LLM `{CorrectionModelRunner,TypoFreeModelDownloader,MLXModelManager,MLXQwenRunner,MLXCorrectionProvider,LLMProviderFactory}.swift`（删 `TypoFreeLLMScaffold.swift`）。测试：Core `LLMTestSupport/CorrectionValidatorTests/CorrectionCoordinatorTests/CorrectionPromptBuilderTests/NullProviderTests/FoundationModelsProviderTests.swift`（删 `NullProviderPlaceholderTests.swift`）；LLM `LLMTestSupport/MLXCorrectionProviderTests/LLMBackendResolverTests/MLXModelManagerLiveTests.swift`（删 scaffold test）。
- **M4 决策记录（DECISIONS>DESIGN 冲突处 + additive 签名，非违规偏离）**：
  1. **prompt userPrompt 尾行**：DECISIONS「port v3 verbatim」胜 DESIGN §2.4 字面。用 v3 的 `…\n候选:<engineBest>\n输出:`（非 DESIGN 的 `…\n只输出修正后的句子。`）。few-shot = 真 user/assistant chat turns（v3 shape）。
  2. **D12 门 = 逐字命中率**（非 `canRead` 全或无）：`命中率≥minHomophoneRatio(0.5)`，锚 `rawPinyin` codes，`readings(of:)` 任一读音。5 例全过；多音字用真 `readings.bin`（银**行**=hang 非首读 xing、得=dei 非首读 de）证明多读音数据源修好。
  3. **additive 构造参数**（DESIGN 签名的超集，默认值保持原调用点有效）：`MLXQwenRunner.init` 加 `modelID/promptBuilder/cacheDirectory/mirrorHost`（+ `init(manager:)` 供 factory 共享同一 `MLXModelManager`，避免两处各载一份权重）；`MLXModelManager.init` 加 `downloader/promptBuilder/gpuCacheLimitBytes`；`LLMBackendResolver.resolve` 加默认 `promptBuilder`。均为 additive，`MLXQwenRunner()`/`resolve(mlxManager:preference:)` 原样可用。
  4. **`Downloader` 是本仓自定义端口**（非 swift-transformers 的 `Downloader`）——`ensureModel`/`hasLocalModel`，探测顺序 app 缓存→`~/.cache/huggingface/hub`→下载(HF→hf-mirror)。
  5. **`CorrectionPromptBuilder.swift`**：DESIGN §1 文件树未显式列它（列在 §2.4 接口里），落 `LLM/` 下；FM(Core)+MLX(LLM) 共用，故必须在 Core。
  6. **`ChatSession` 非 Sendable**：`MLXModelManager.run` 的 session 构造+`respond` 挪进 `nonisolated static func generate(…)`（只收 Sendable 参数：`ModelContainer`/`[Shot]`/String/Int），不跨 actor 边界（Swift 6 strict-concurrency）。`enable_thinking:false` 抽成 `static let thinkingDisabledContext` 供断言。
- **M4 live 测试环境限制（非代码缺陷，给 M5/M9）**：`TYPOFREE_MLX_LIVE_TEST=1`（+ 新增 `TYPOFREE_MLX_CACHE_DIR` 可指向预置权重，本次用 VoxInk assetpack 的完整 Qwen3-0.6B-4bit 做 symlink 种子避开下载）跑到 **MLX Metal 边界即挂**：`MLX error: Failed to load the default metallib`——`.build` 树内**根本没有 default.metallib**，mlx-swift 的 Metal shader 库在 `swift test` CLI 下不产出/不打包（需 app bundle）。下载探测 + config/tokenizer 载入路径**已验证可用**（用本地权重零下载）；真 GPU 推理只能在 M5+ 的 Xcode app target 里验（那时 metallib 正常打包）。`swift test` 默认仍绿（live 被门控 skip）。

## M5 — app shell：IMK controller + 候选窗 + 异步 slot#1 `[Shell]` (dep M4)
- [ ] `TypoFree.xcodeproj`（显式 PBXFileReference/PBXGroup、两个 XCLocalSwiftPackageReference、`SWIFT_VERSION=6`、`MACOSX_DEPLOYMENT_TARGET=26.0`、**controller 无 @objc 改名**）—— 首建用 Xcode "Add Local Package…"
- [ ] `Info.plist`(LSUIElement=true/LSBackgroundOnly=false/NSPrincipalClass/InputMethodConnectionName/ControllerClass/ComponentInputModeDict) + `TypoFree.entitlements`(app-sandbox=false)
- [ ] `main.swift`(argv 分发) + `TypoFreeApp`(非 @main) + `AppDelegate`(IMKServer + 启动 resolve provider) + `TypoFreeInstaller`(TIS register/enable/select/quit)
- [ ] `TypoFreeInputController: IMKInputSessionController` + `IMKTextClientAdapter`(IMKTextInput→TextClient) + `NSEvent+KeyEvent` + `InputSessionCache`(weak-LRU cap5, 仅组合态重接)
- [x] `InputSession`(Core/Session, @MainActor 状态机, IMK-free)：路由(a-z/1-9/Space/Return/Backspace/Escape/Command/孤 Shift 中英切换) + commit 内容模型(显式=recommended/隐式=engineBest/Return=verbatim) + 订阅 coordinator.events 按 requestID apply。**MF#4**（不再自持 gen-token+Task.sleep）
- [ ] `CandidatePanel: NSPanel(.nonactivatingPanel)` + 自绘 `CandidateBarView: NSView.draw(_:)`(固定 slot 几何、slot#1 无 reflow、`.computing/.landed/.unavailable`)。**MF#11**（删 scaffold SwiftUI CandidateView）
- [ ] 并发契约实现：MainActor 同步建 snapshot（快 IMKTextInput 路径 <5ms）→ coordinator off-main → 回 MainActor apply（并发风险 #1：AX 不上热路径）
- [x] 测试 [Core, InputSession 用 mock]：路由/Space 接受/Return verbatim/异步 slot#1 provisional→landed 不 reflow/stale by requestID/NullProvider→unavailable/`handle` 同步 <5ms/LRU 重接/**零声母陷阱真引擎集成**(歪/为/万/王/要/有/羊/用 commit 正确)
- [ ] `scripts/dev.sh` + `make-dev-cert.sh`
- **交付**：真机可切到小鹤双拼打字、slot#2 即时 slot#1 异步不卡。**验证**：dev.sh 装 → System Settings 加 → TextEdit 打字。**依赖**：M4。

## M6 — 上下文 reader + AX + secure-field `[Shell]` (dep M5)
- [ ] Core 纯逻辑：`SecureFieldGuard`(动态`IsSecureEventInputEnabled`+静态标记表、短 token 整词边界) + `IdentitySignature`/`RoundedFrame`/`FieldSignature` + `SendDetectionSession` 纯状态机 + `ContextSnapshot`/tier/suppression。**MF#6**（AX 触碰代码全出 Core，Core 只留纯值+纯逻辑）
- [ ] app-shell 真实 AX：`ContextReadLadder`(IMKTextInput→AX→sentence-only) + `AXFocusResolver`(systemWide+50ms timeout+`AXUIElementGetPid`) + `AXContextReader` + `SecureInputMonitor` + denylist(Terminal/iterm2)
- [ ] `ContextReading` wire 协议：`precedingContext`(LLM 快路径) + `isSecureContext` + `captureSnapshot`(commit 时全抓)。**MF#5**（统一 context 协议）
- [ ] 测试 [Core]：`SecureFieldGuard`(AXSecureTextField真/"one-time code"真/"Opinion"假/"Pinyin"假) + `SendDetectionSession`(unresolved==empty==sessionEnded) + denylist
- **交付**：上下文 ladder + secure 双保险真机可用。**验证**：Safari/Messages 打字上下文优雅退化、密码框学习 inert。**依赖**：M5。

## M7 — 学习循环 + userdict `[Shell]`+`[Core]` (dep M6)
- [ ] `MyersDiff` + `DiffLearner`(纯：编辑脚本分组 + 拒绝门 editRatio>0.5/lengthDelta>0.6 + ≤4 豁免 + 逐 op 分类 用 `PinyinReadingIndex` 读音交集/`encode(tonelessSyllables:)`)
- [ ] `UserDictStore`(actor, **原生 sqlite3, 弃 GRDB**, WAL, 4 表, occurrence≥2→boost=log(1+count), clearAll+checkpoint+VACUUM)。**MF#10**（选定库+类型+schema）
- [ ] `OverlayHost`(不可变 snapshot 原子换入) + `UserDictStore.loadBoostOverlay` 接线到 `SessionDependencies.overlayProvider`。**MF#8**（overlay 表征定为不可变换入）
- [ ] `LearningLoopCoordinator`(唯一 send-detect+LRU 归属, cap5) + app-shell `SendDetectionPoller`(持 commit 时抓的引用轮询, 1.5s, 仅有未 flush 会话时起 timer)。去三处重叠 LRU（DESIGN §4）
- [ ] `CommitObserver.didCommit(committed:spans:sessionID:snapshot:)` 携带 `WordSpan`(engine.bestPath)+`ContextSnapshot`(含 pollTarget)。**MF#7**（commit 契约线出 keySeq/overlay key/pollTarget）
- [ ] 测试 [Core]：`DiffLearner`(≤4 救单字换/editRatio 拒/lengthDelta 边界 0.6过0.7拒/OOV 陷阱 keySeq 外→wd 王→wh) + `UserDictStore`(occurrence<2 不影响/==2 促进/clearAll/并发不坏 WAL) + `LearningLoopCoordinator.isPolling` CPU 不变量
- **交付**：改字→send-detect→学习→后续排名升，端到端。**验证**：真机多 app：打短语改字发送，验证学习事件记录 + 后续候选提升。**依赖**：M6。

## M8 — Settings / onboarding / 模型下载 UX `[Shell]` (dep M7)。**MF#12**
- [ ] `BackendPickerView`(probeBackends 列 FM/MLX/Off + 改选热切换 `coordinator.setProvider` 先释放旧 MLX)
- [ ] **ModelPreset 双预设 + RAM 感知默认**(bake-off 拍板,M4 只做了 modelID 参数化没做策略):quality=`mlx-community/Qwen2.5-1.5B-Instruct-4bit`(默认当 RAM≥16GB)/ light=`mlx-community/Qwen3-0.6B-4bit`(<16GB);UserDefaults 持久化;picker 里可切;displayName 不再硬编码 0.6B
- [ ] `ModelDownloadView`(下载进度 fraction + 触发/取消 + HF/hf-mirror 显示)
- [ ] `PermissionView`(AX TCC 弹窗 + 未授权态 + 授权后重查；核心打字不依赖 AX)
- [ ] `OnboardingView`(System Settings 启用引导 + **首装登出/登入**提示)
- [ ] `SettingsView`(清除学习数据 + 中文隐私声明) + `MenuBarView`(后端 glyph + 错误浮层：MLX 双源挂 / FM `.rateLimited`)
- [ ] `menuicon.tiff` + `Assets.xcassets` app icon
- **交付**：全部首运行/设置 UX 齐。**验证**：手动走完首装→授权→下载→选后端→清除。**依赖**：M7。

## M9 — 真机测试 + 两个 spike `[Shell]` (dep M8)
- [ ] **Spike 0(新增,M4 发现)**:验证 Xcode app bundle 构建产出并包含 mlx 的 `default.metallib`(`find TypoFree.app -name "*.metallib"`)+ 首次真 GPU 推理冒烟(swift test CLI 不产 metallib,MLX 真路径在 M4 只验到 Metal 边界)
- [ ] **Spike 1**：最小 FM harness 多小时背景 `respond()` → 背景 IME 会不会 `.rateLimited`（DECISIONS §4，决定 FM 降级策略 user-Q2）
- [ ] **Spike 2**：`imklaunchagent` 托管 `~/Library/Input Methods` bundle 能否拿 AX/TCC 授权（无参考 IME 验过；ad-hoc 签名 TCC 重置用 make-dev-cert.sh 缓解）
- [ ] 走完 DESIGN §9 手动真机清单（TextEdit/Safari/Messages/密码框/清除/FM-MLX 不可用降级）
- [x] ~~user-Q1 决议后 OpenCC~~ → 已拍板并提前到 M2 执行（构建期繁→简）
- **交付**：核心典型场景真机验收 + 两风险去除。**验证**：清单逐项通过 + spike 结论记录。**依赖**：M8。

## M10 — 签名 / 公证 / dev 循环固化 `[Shell]` (dep M9)
- [ ] Developer ID 签 + notarize + Hardened Runtime（MLX/Metal JIT 可能需 `com.apple.security.cs.disable-library-validation`/`allow-unsigned-executable-memory`）
- [ ] `dev.sh` 固化（build→quit→copy→register/enable/select，每用户 `~/Library/Input Methods`，首装登出/登入，之后 killall 热换）
- **交付**：可分发构建 + 稳定 dev 循环。**验证**：全新机安装启用打字。**依赖**：M9。

---

## must_fix → 里程碑 映射速查
- MF#1 TFX1 统一 → M2 · MF#2 多音字侧车 → M2 · MF#3 单 provider 协议+coordinator 门 → M4(+M3 overlay 参数)
- MF#4 单异步编排 → M4/M5 · MF#5 统一 Scheme/Decoder/结果/Candidate/context 协议 → M1/M3/M6
- MF#6 AX 出 Core → M6 · MF#7 commit 契约 → M7 · MF#8 overlay 进 recompute+不可变换入 → M3/M7
- MF#9 包拓扑 → M0 · MF#10 userdict 原生 sqlite3 → M7 · MF#11 自绘候选窗 → M5 · MF#12 UX owner → M8
