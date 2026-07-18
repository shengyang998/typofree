# TypoFree — 实现里程碑清单 (tasks.md)

> 依据 `DESIGN.md`。每个里程碑独立可构建 + 可验证 + 可提交（plan-act-test loop）。
> `[Core]` = 纯 TypoFreeCore/TypoFreeLLM，可 `swift test` 由隔离 agent 独立构建，无需 app shell/真机。
> `[Shell]` = 需 app-shell 接线 / 登录会话 / 真机测试。
> 工程评审 12 条 `must_fix` 已折进对应里程碑（标 **MF#n**）。

---

## M0 — 脚手架 `[Core]` (parallelizable)
- [ ] 建两个 SPM 包目录 + `Package.swift`：`TypoFreeCore`（零依赖 + `CSQLite` system-library shim）、`TypoFreeLLM`（path dep Core + 钉 `mlx-swift-lm 2.31.3` + `swift-transformers 1.2.0`）。**MF#9**（统一目录根 `labs/typofree/TypoFreeCore`、`TypoFreeLLM`、`TypoFree.xcodeproj`、`TypoFree/`）
- [ ] `CSQLite/module.modulemap` + `shim.h`（`#include <sqlite3.h>`, `link "sqlite3"`）
- [ ] 符号链接 `Resources/lexicon.bin` → `../../../../data/lexicon.bin`（`readings.bin` 待 M2 产出后补链）
- [ ] 占位 `SchemeDefinition` + `NullProvider` + `Fixtures/mini-lexicon.bin`（手写小 TFX1）打通 `swift test`
- **交付**：`cd TypoFreeCore && swift test` 绿（占位）。**验证**：CI 无网络跑通。**依赖**：无。

## M1 — Scheme + Decoder `[Core]` (parallelizable, dep M0)
- [ ] `InitialClass`(5 类) + `SchemeDefinition`(`schemeId:UInt16=1`) + `FlypyScheme.flypy`（全部 Appendix A：21 声母键、`v/i/u→zh/ch/sh`、joint `finalTable`、35 条零声母表）。**MF#5**（统一为一套 Scheme/Decoder，`schemeId` == TFX1 header）
- [ ] `ShuangpinDecoder.decode/decodeSyllable/encode(syllable:)/encode(tonelessSyllables:)`（正反向，init 内反演反向表 + precondition 单射校验）
- [ ] 测试：**8 陷阱**(wai→wd…yong→ys) + 常规对照(yu/yuan/yue/yun/wu/aa/er) + 重载键(o/k/l/s/x/v/t) + r=uan/n=iao 条件例外 + 压缩声母 + 非法组合→nil + 反向 encode 往返(你好→nihc、世界→uijp) + 单实例(不受第二 scheme 影响)
- **交付**：decoder 全测过。**验证**：`swift test --filter Scheme`。**依赖**：M0。

## M2 — 词库加载 + 多音字侧车 `[Core]` (dep M1)
- [ ] `LexiconBlobFormat`（**TFX1** 16B header、`loadUnaligned` 多字节、posting `wordLen→word→logFreq`、`logFreq=ln(1+rawCount)`）。**MF#1**（删 engine 原 `TFLX`，全线用 TFX1）
- [ ] `LexiconStore.loadBundled/init(data:)/postings(forKey:)/maxSyllables`
- [ ] **`build_lexicon.py` 增补 `readings.bin`（TFXR v1）**：`pinyin.txt` 每单字**全部**无调读音编成 `[Character:[String]]`。**MF#2**（D12 门必须的多音字数据源；否则 false-reject 的/地/得）
- [ ] **`build_lexicon.py` 加构建期 OpenCC 繁→简**（user-Q1 已拍板，从 M9 提前）：opencc-python-reimplemented，同形合并频次，重跑产纯简体 `lexicon.bin`；重验 你好→nihc + 8 零声母陷阱 + `postings("aa")` 期望值改为简体序
- [ ] `PinyinReadingIndex.loadBundled/readings(of:)/canRead(_:asShuangpinCodes:decoder:)/isAllHanzi`（接受任一读音，多音字安全）
- [ ] 补 `readings.bin` 符号链接 + `Package.swift` resources
- [ ] 测试：真 `lexicon.bin` 载入(`postings("aa")==[啊,阿,錒,嗄,锕]` 顺序 + 载入时间预算) + bad magic/version/truncated 抛错 + fixture 往返 + `readings.bin` 多音字覆盖(行→[xk,hh]、得→[de,dei])
- **交付**：真 blob + 侧车端到端载入。**验证**：`swift test --filter Lexicon`。**依赖**：M1。

## M3 — Lattice + Viterbi + user-boost overlay `[Core]` (dep M2)
- [ ] `WordSpan`/`Candidate`/`EngineResult`(超集：engineBest+bestPath+focusCandidates+preeditDisplay+hanziCount+endsAtClauseBoundary+incompleteTail)。**MF#5**（统一结果类型）
- [ ] `UserBoostOverlay`(不可变 snapshot, 加性 delta) + `LatticeConfig`
- [ ] `Lattice` + `ConversionEngine.convert(_:overlay:focus:)`（每键全量重算、length bonus、兜底连通、tie-break 确定）。**MF#8**（overlay 必进 recompute，否则学习 inert）
- [ ] `CandidateEngine` wire 协议带 `overlay` 参数。**MF#3**（修 overlay 到不了 lattice 的漏洞）
- [ ] `EngineResult.preeditDisplay` 按 hybrid 默认产（见 user-Q3）
- [ ] 测试：短语胜单字 / 稀有短语让位 / tie-break 确定 / 非法音节兜底 / **overlay 加性 boost 改排名回归**
- **交付**：确定性引擎全测过。**验证**：`swift test --filter Engine`。**依赖**：M2。

## M4 — LLM providers + 校验门 + coordinator `[Core]`+`[LLM]` (dep M3)
- [ ] 唯一 `LLMCorrectionProvider` 协议 + `CorrectionRequest`/`CorrectionResult`(RAW) + `NullProvider`(返回 nil)。**MF#3**（四协议收敛：nil=放弃、provider 产 RAW、门在 coordinator）
- [ ] `CorrectionValidator`(D12：全汉字→长度±1→`canRead` 任一读音命中率，比较空间=codes)
- [ ] `CorrectionCoordinator`(actor, Core)：防抖/取消/触发门/emit==最新 requestID。**MF#4**（唯一异步编排，staleness=requestID）
- [ ] `CorrectionPromptBuilder`(systemInstructions byte-identical + few-shot)
- [ ] `FoundationModelsCorrectionProvider`(Core, `#if canImport(FoundationModels)`, @Generable + timeout race)
- [ ] `CorrectionModelRunner` 端口 + `MLXQwenRunner`(Qwen3-0.6B-4bit, enable_thinking:false, temp 0) + `MLXCorrectionProvider`(actor, 状态机/按需载/闲卸双保险) + `TypoFreeModelDownloader`(HF→hf-mirror, App Support 缓存) [LLM]
- [ ] `MLXModelManager` + `LLMProviderFactory` + `LLMBackendResolver`(FM→MLX→Null) [LLM]
- [ ] provider 隔离硬契约断言：`correct()` 期间不占 MainActor（并发风险 #2）
- [ ] 测试 [Core]：门 5 例(接受同音/拒 latin/拒长度/拒幻觉/**多音字不误拒**) + coordinator(防抖单次/clause 跳防抖/新键取消/stale-drop by requestID/超时→nil/卡死不死锁) 全用 `FakeModelRunner`+fake provider
- [ ] 测试 [LLM]：`LLMBackendResolver` fake 两分支零网络；`MLXModelManagerLiveTests` 门控 `TYPOFREE_MLX_LIVE_TEST=1`(真下载+`additionalContext["enable_thinking"]==false`+无`<think>`)
- **交付**：整个异步修正状态机零 Metal 可测；MLX 真路径集成测试可选跑。**验证**：`swift test`(Core+LLM) + `TYPOFREE_MLX_LIVE_TEST=1 swift test`(dev box)。**依赖**：M3。

## M5 — app shell：IMK controller + 候选窗 + 异步 slot#1 `[Shell]` (dep M4)
- [ ] `TypoFree.xcodeproj`（显式 PBXFileReference/PBXGroup、两个 XCLocalSwiftPackageReference、`SWIFT_VERSION=6`、`MACOSX_DEPLOYMENT_TARGET=26.0`、**controller 无 @objc 改名**）—— 首建用 Xcode "Add Local Package…"
- [ ] `Info.plist`(LSUIElement=true/LSBackgroundOnly=false/NSPrincipalClass/InputMethodConnectionName/ControllerClass/ComponentInputModeDict) + `TypoFree.entitlements`(app-sandbox=false)
- [ ] `main.swift`(argv 分发) + `TypoFreeApp`(非 @main) + `AppDelegate`(IMKServer + 启动 resolve provider) + `TypoFreeInstaller`(TIS register/enable/select/quit)
- [ ] `TypoFreeInputController: IMKInputSessionController` + `IMKTextClientAdapter`(IMKTextInput→TextClient) + `NSEvent+KeyEvent` + `InputSessionCache`(weak-LRU cap5, 仅组合态重接)
- [ ] `InputSession`(Core/Session, @MainActor 状态机, IMK-free)：路由(a-z/1-9/Space/Return/Backspace/Escape/Command/孤 Shift 中英切换) + commit 内容模型(显式=recommended/隐式=engineBest/Return=verbatim) + 订阅 coordinator.events 按 requestID apply。**MF#4**（不再自持 gen-token+Task.sleep）
- [ ] `CandidatePanel: NSPanel(.nonactivatingPanel)` + 自绘 `CandidateBarView: NSView.draw(_:)`(固定 slot 几何、slot#1 无 reflow、`.computing/.landed/.unavailable`)。**MF#11**（删 scaffold SwiftUI CandidateView）
- [ ] 并发契约实现：MainActor 同步建 snapshot（快 IMKTextInput 路径 <5ms）→ coordinator off-main → 回 MainActor apply（并发风险 #1：AX 不上热路径）
- [ ] 测试 [Core, InputSession 用 mock]：路由/Space 接受/Return verbatim/异步 slot#1 provisional→landed 不 reflow/stale by requestID/NullProvider→unavailable/`handle` 同步 <5ms/LRU 重接/**零声母陷阱真引擎集成**(歪/为/万/王/要/有/羊/用 commit 正确)
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
- [ ] `ModelDownloadView`(下载进度 fraction + 触发/取消 + HF/hf-mirror 显示)
- [ ] `PermissionView`(AX TCC 弹窗 + 未授权态 + 授权后重查；核心打字不依赖 AX)
- [ ] `OnboardingView`(System Settings 启用引导 + **首装登出/登入**提示)
- [ ] `SettingsView`(清除学习数据 + 中文隐私声明) + `MenuBarView`(后端 glyph + 错误浮层：MLX 双源挂 / FM `.rateLimited`)
- [ ] `menuicon.tiff` + `Assets.xcassets` app icon
- **交付**：全部首运行/设置 UX 齐。**验证**：手动走完首装→授权→下载→选后端→清除。**依赖**：M7。

## M9 — 真机测试 + 两个 spike `[Shell]` (dep M8)
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
