# TypoFree — 权威构建规格 (DESIGN.md)

> macOS 小鹤双拼输入法 + 端上 LLM 错别字修正。本文件是实现者唯一的编码依据，
> 已把六份模块设计 + 工程评审的所有 `must_fix`/接口冲突**协调为一套自洽契约**。
> 冲突处一律以本文件为准。锁定基线见 `research/DECISIONS.md`（本文件从属于它）。
> 日期 2026-07-18。
>
> ⚠️ **实现期偏差记录在 `tasks.md` 各里程碑的「交付确认」块里,本文件不回溯改写。**
> 已知与实现不一致处(以 tasks.md/代码为准):swift-tools-version 实为 6.2(非 6.1);
> lexicon.bin 真实字节在 `TypoFreeCore/Sources/TypoFreeCore/Resources/`(`data/` 侧是符号链接,方向与 §1 原文相反);
> `postings("aa")` OpenCC 后为 4 项简体序;§2.1 重载键散文表以 rime 真源为准(见 M1 交付确认);
> swift-transformers 无 umbrella module(`import Tokenizers` 等子模块);MLX 修正模型为 RAM 感知双预设(见 DECISIONS bake-off 节,非固定 0.6B)。
> 优先级:**DECISIONS.md > tasks.md 交付确认 > 本文件 > EXPLORE.md**。

---

## 0. 概览与模块图

TypoFree 是一个 **unsandboxed** 的 macOS 26.x 菜单栏输入法：Mac 键盘上敲小鹤双拼，
自绘候选窗，slot#1 由端上小 LLM 异步给出「同音/错别字修正」，从不阻塞打字线程。
LLM 后端运行时三选一（FM → MLX → Null），后端不可用时静默退化到确定性 engineBest。

```
┌──────────────────────────────────────────────────────────────────────────┐
│  TypoFree.app (Xcode app shell — 唯一 import IMKit/AppKit/AX 的地方)        │
│                                                                            │
│  main.swift(argv 分发) → TypoFreeApp(MenuBarExtra+Settings)                │
│  AppDelegate ── IMKServer ── TypoFreeInputController : IMKInputSessionCtrl  │
│      │                            │                                         │
│      │       ┌────────────────────┼─────────────────────────────┐          │
│      │  IMKTextClientAdapter  CandidatePanel(自绘NSView)  ContextReadLadder │
│      │   (IMKTextInput→        (slot#1 fixed-geo,         (IMKTextInput→AX  │
│      │    TextClient)           async 更新)                →sentence-only)  │
│      │                            │                            │            │
│      ▼                            ▼                            ▼            │
│  InputSession(@MainActor 状态机) ── 调 ──► CandidateEngine / CorrectionCoord │
│      │  commit → CommitObserver(word,WordSpan,keySeq,ContextSnapshot,sid)   │
└──────┼─────────────────────────────────────────────────────────────────────┘
       │ 仅通过纯协议 + Sendable 值类型跨界
┌──────▼──────────────────────────────────┐   ┌───────────────────────────────┐
│ TypoFreeCore (SPM, 零外部依赖, swift test)│   │ TypoFreeLLM (SPM, 隔离 MLX/Metal)│
│  Scheme: SchemeDefinition/FlypyScheme/    │   │  MLXCorrectionProvider(actor)  │
│          ShuangpinDecoder                 │   │  MLXModelManager(按需载/闲卸)   │
│  Engine: ConversionEngine/Lattice/Viterbi │   │  MLXHubCache(→App Support)     │
│  Lexicon: TFX1 reader/LexiconStore/       │◄──┤  LLMBackendResolver(FM→MLX→Null)│
│           PinyinReadingIndex(多音字)       │   │  依赖: TypoFreeCore(path) +     │
│  Learning: MyersDiff/DiffLearner(纯)/      │   │       mlx-swift-lm+transformers │
│            LearningLoopCoordinator         │   └───────────────────────────────┘
│  UserDict: UserDictStore(actor, 原生sqlite)│
│  Context(纯): SecureFieldGuard/            │   CSQLite (system-library shim)
│    IdentitySignature/SendDetectionSession  │
│  LLM: LLMCorrectionProvider(协议)/         │
│    NullProvider/FoundationModelsProvider/  │
│    CorrectionValidator(D12门)/             │
│    CorrectionCoordinator(actor,防抖/取消)   │
│  Wire 协议: CandidateEngine/ContextReading/ │
│    CommitObserver/CandidateRendering        │
└─────────────────────────────────────────────┘
```

**分层原则**（工程评审 must_fix #6/#9）：
- **TypoFreeCore = 纯 Swift + CSQLite，零 AppKit/IMKit/ApplicationServices import**，可
  `cd TypoFreeCore && swift test` 独立跑，不触网、不解析 MLX、不需要登录会话。所有
  AX/IMK 的**真实系统调用**都在 app shell；Core 只持有纯值类型和纯逻辑
  （`SecureFieldGuard` 字符串匹配、`DiffLearner`、`IdentitySignature`、
  `SendDetectionSession` 状态机）。
- **TypoFreeLLM** 只装 MLX + `MLXModelManager` + `LLMBackendResolver`。FM Provider 用
  系统 framework，**放在 Core**（零额外依赖、零 Metal），MLX 才是需要隔离的重依赖。
- **app shell** 同时 link 两个本地包，启动时调一次 `LLMBackendResolver.resolve(...)`。

---

## 1. 项目结构

```
labs/typofree/
├── research/              # DECISIONS.md, EXPLORE.md (锁定基线, 不改)
├── data/                  # 词库产物 (lexicon-build 任务已产出)
│   ├── lexicon.bin        # 真实, 已构建, TFX1 v1, 9,093,289 bytes
│   ├── readings.bin       # 【新增】多音字侧车 (build 增补, must_fix #2), TFXR v1
│   ├── lexicon_sample.tsv
│   ├── README.md          # 词库来源 + license, 必须复制进 Settings/About
│   └── sources/{essay.txt,large_pinyin.txt,pinyin.txt}
├── tools/                 # uv-managed Python
│   ├── build_lexicon.py   # 产出 lexicon.bin + 【新增】readings.bin
│   ├── pyproject.toml uv.lock
│
├── TypoFreeCore/                       # SPM 包 #1 — 零外部依赖
│   ├── Package.swift
│   └── Sources/
│       ├── CSQLite/{module.modulemap, shim.h}          # sqlite3 system shim
│       └── TypoFreeCore/
│           ├── Resources/lexicon.bin  → 符号链接 ../../../../data/lexicon.bin
│           ├── Resources/readings.bin → 符号链接 ../../../../data/readings.bin
│           ├── Scheme/{SchemeDefinition, FlypyScheme, ShuangpinDecoder}.swift
│           ├── Engine/{Syllable, Candidate, Lattice, ConversionEngine}.swift
│           ├── Lexicon/{LexiconPosting, LexiconBlobFormat, LexiconStore,
│           │            PinyinReadingIndex}.swift
│           ├── Overlay/UserBoostOverlay.swift          # 不可变 snapshot
│           ├── Learning/{MyersDiff, DiffLearner, CommittedSpan,
│           │             LearningLoopCoordinator, RepinyinizerContracts}.swift
│           ├── UserDict/{UserDictStore, SQLite3Statement, UserDictSchema}.swift
│           ├── Context/{IdentitySignature, SecureFieldGuard,
│           │            SendDetectionSession}.swift    # 纯值/纯逻辑, 无 AX
│           ├── LLM/{LLMCorrectionProvider, NullProvider,
│           │       FoundationModelsProvider, CorrectionValidator,
│           │       CorrectionCoordinator, CorrectionTypes}.swift
│           ├── Session/InputSession.swift              # @MainActor 状态机 (IMK-free)
│           └── Wire/{CandidateEngine, ContextReading, CommitObserver,
│                     CandidateRendering, TextClient, KeyEvent,
│                     CandidateBarModel, Config, SessionDependencies}.swift
│   └── Tests/TypoFreeCoreTests/... (见 §8)
│
├── TypoFreeLLM/                        # SPM 包 #2 — 隔离 MLX/Metal
│   ├── Package.swift                   # path dep ../TypoFreeCore + mlx-swift-lm + swift-transformers
│   └── Sources/TypoFreeLLM/{MLXModelManager, MLXHubCache, MLXQwenRunner,
│                            MLXCorrectionProvider, TypoFreeModelDownloader,
│                            LLMProviderFactory, LLMBackendResolver}.swift
│   └── Tests/TypoFreeLLMTests/{LLMBackendResolverTests, MLXModelManagerLiveTests}.swift
│
├── TypoFree.xcodeproj/                 # 显式 PBXFileReference/PBXGroup (非 synchronized),
│                                       # 两个 XCLocalSwiftPackageReference。首建用 Xcode
│                                       # "Add Local Package…" 生成, 之后手维护。
├── TypoFree/                           # app shell (module = "TypoFree")
│   ├── main.swift TypoFreeApp.swift AppDelegate.swift TypoFreeInstaller.swift
│   ├── IMK/{TypoFreeInputController, TypoFreeServerDelegate, IMKTextClientAdapter,
│   │        InputSessionCache, NSEvent+KeyEvent}.swift
│   ├── Context/{ContextReadLadder, AXFocusResolver, AXContextReader,
│   │            SendDetectionPoller, SecureInputMonitor}.swift  # 真实 AX 调用在这
│   ├── CandidateWindow/{CandidatePanel, CandidateBarView}.swift # 自绘 NSView
│   ├── UI/{MenuBarView, SettingsView, ModelDownloadView, OnboardingView,
│   │       PermissionView, BackendPickerView}.swift
│   ├── Info.plist TypoFree.entitlements menuicon.tiff Assets.xcassets
│   └── ...
├── TypoFreeTests/AppLaunchArgsTests.swift
└── scripts/{dev.sh, make-dev-cert.sh}
```

### Package.swift × 2

```swift
// TypoFreeCore/Package.swift — swift-tools-version: 6.1
let package = Package(
    name: "TypoFreeCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TypoFreeCore", targets: ["TypoFreeCore"])],
    dependencies: [],                                  // 刻意为空 — 这是整个隔离的意义
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "TypoFreeCore", dependencies: ["CSQLite"],
                resources: [.copy("Resources/lexicon.bin"), .copy("Resources/readings.bin")]),
        .testTarget(name: "TypoFreeCoreTests", dependencies: ["TypoFreeCore"],
                    resources: [.copy("Fixtures")]),
    ])
// CSQLite/module.modulemap: module CSQLite [system] { header "shim.h"; link "sqlite3"; export * }
// CSQLite/shim.h: #include <sqlite3.h>

// TypoFreeLLM/Package.swift — swift-tools-version: 6.1
let package = Package(
    name: "TypoFreeLLM",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TypoFreeLLM", targets: ["TypoFreeLLM"])],
    dependencies: [
        .package(path: "../TypoFreeCore"),
        // 刻意钉在 2.x 末线 — 3.x(HEAD 2026-07-17) 把自带 HubApi loader 换成
        // Downloader/TokenizerLoader 协议对, 且自身 README 有产品名漂移。升级前必重验。
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.31.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.2.0")),
    ],
    targets: [
        .target(name: "TypoFreeLLM", dependencies: ["TypoFreeCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Transformers", package: "swift-transformers")]),
        .testTarget(name: "TypoFreeLLMTests", dependencies: ["TypoFreeLLM"]),
    ])
```

### Xcode app-shell 关键设置（对齐 KeyBridge，deltas 标注）

| 设置 | 值 | 说明 |
|---|---|---|
| target/`PRODUCT_NAME` | `TypoFree` | ⇒ `PRODUCT_MODULE_NAME=TypoFree`，匹配 `$(PRODUCT_MODULE_NAME).TypoFreeInputController` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.soleilyu.inputmethod.TypoFree` | 锁定 |
| `MACOSX_DEPLOYMENT_TARGET` | `26.0` | FM 的运行期分支 (`isAvailable`)，非部署下限；MLX/Null 必须在 26.0 可用 |
| `SWIFT_VERSION` | `6` | 偏离 KeyBridge 的 5.0 — 全程依赖 actor 隔离 |
| `GENERATE_INFOPLIST_FILE` | `YES` + 真实 `INFOPLIST_FILE` | KeyBridge 同款合并模式 |
| `CODE_SIGN_STYLE` | `Automatic` | ad-hoc/dev；Developer ID + notarize 推到 M10 |
| 链接 framework | `InputMethodKit`, `Carbon`, `ApplicationServices` | 均无需 entitlement key |
| **关键**：`TypoFreeInputController` **不加** `@objc` 改名 | | 否则 mangled 名丢 module 前缀，`NSClassFromString` 解析失败、IME 静默收不到事件 |

### 词库符号链接（scaffold §7）

SPM 资源必须落在 target 目录内；`data/lexicon.bin` 是 Python 构建脚本的规范产物，用符号链接桥接（git 原生跟踪符号链接）：
```bash
cd labs/typofree/TypoFreeCore/Sources/TypoFreeCore/Resources
ln -s ../../../../data/lexicon.bin  lexicon.bin
ln -s ../../../../data/readings.bin readings.bin
```

---

## 2. 每模块设计（协调后的统一 Swift 接口）

> 以下是**唯一一套**类型定义。凡六份原设计里名字/形状冲突的（四个
> `LLMCorrectionProvider`、三个 `SchemeDefinition`、三个引擎结果类型、三处 send-detect
> LRU……），此处已收敛，实现者照此编码。

### 2.1 Scheme + Decoder（TypoFreeCore/Scheme）

统一到 scaffold 的 `schemeId: UInt16`（**必须 == TFX1 header schemeId = 1**），保留 engine
的 joint `(initialClass, finalKey)→final` 表 + 35 条零声母表。小鹤是**唯一实例** `FlypyScheme.flypy`。

```swift
public struct InitialClass: Sendable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
extension InitialClass {   // flypy 的最小 5 类划分 (EXPLORE Appendix A)
    public static let bpmf   = InitialClass(rawValue: "bpmf")   // b p m f
    public static let dt     = InitialClass(rawValue: "dt")     // d t
    public static let nl     = InitialClass(rawValue: "nl")     // n l
    public static let jqx    = InitialClass(rawValue: "jqx")    // j q x
    public static let gkhzh  = InitialClass(rawValue: "gkhzh")  // g k h zh ch sh r z c s
}

public struct SchemeDefinition: Sendable, Equatable {
    public let schemeId: UInt16                                 // flypy = 1, == TFX1 header
    public let displayName: String                             // "小鹤双拼"
    public let zeroInitialLeadKeys: Set<Character>             // {a,e,o,w,y}
    public let keyToInitial: [Character: String]              // b→"b", v→"zh", i→"ch", u→"sh" (21)
    public let initialToClass: [String: InitialClass]
    public let finalTable: [InitialClass: [Character: String]] // JOINT; 缺项=非法音节
    public let zeroDecodeTable: [String: String]              // 2-char code→syllable (35)
    // init 内反演出的反向表 (precondition 校验单射), 供 encode/reverse:
    public let initialToKey: [String: Character]
    public let finalReverse: [InitialClass: [String: Character]]
    public let zeroEncodeTable: [String: String]
    public init(schemeId: UInt16, displayName: String, zeroInitialLeadKeys: Set<Character>,
                keyToInitial: [Character: String], initialToClass: [String: InitialClass],
                finalTable: [InitialClass: [Character: String]], zeroDecodeTable: [String: String])
    public func initialClass(ofKey k1: Character) -> InitialClass?
}

public enum FlypyScheme { public static let flypy: SchemeDefinition }  // 全部 Appendix A 数据

public struct Syllable: Sendable, Equatable {
    public let code: String          // 2-char 小鹤 code, e.g. "hc"
    public let pinyin: String?       // 解析出的无调拼音 "hao"; nil = 非法组合
    public let isComplete: Bool      // false = 只敲了半个音节 (声母 only)
}
public struct DecodeResult: Sendable, Equatable {
    public let syllables: [Syllable]      // 完整 2-key 音节
    public let incompleteTail: String?    // 末尾单键 (半音节), 否则 nil
    public var codes: [String] { syllables.map(\.code) }
}

public struct ShuangpinDecoder: Sendable {
    public let scheme: SchemeDefinition
    public init(scheme: SchemeDefinition)
    public func decode(_ keys: String) -> DecodeResult              // 按 2 键切块
    public func decodeSyllable(_ twoKeys: String) -> String?        // 2-char code → 无调拼音
    public func encode(syllable pinyin: String) -> String?          // 单音节 反向: 拼音→2-char code
    public func encode(tonelessSyllables: [String]) -> String?      // 多音节: [wai]→"wd" (统一 ShuangpinEncoder 契约)
}
```

**8 个反直觉零声母陷阱**（强制测试用例，全流程必须过）：
`wai→wd, wei→ww, wan→wj, wang→wh, yao→yc, you→yz, yang→yh, yong→ys`。
常规对照（防止过度改写）：`yu→yu, yuan→yr, yue→yt, yun→yy, wu→wu, aa→a, er→er`。

### 2.2 词库 + TFX1 blob（TypoFreeCore/Lexicon）— must_fix #1

**唯一 blob 契约 = TFX1**（磁盘已验证 `data/lexicon.bin` 开头 `54 46 58 31`）。
**删除 engine 原设计的 `TFLX`**。16 字节头，posting 顺序 `wordLen→word→logFreq:Float32`，
`logFreq = ln(1+rawCount)`（**不含** length bonus，length bonus 是 Swift 端 Viterbi 的活）。

```
HEADER (16B, LE): magic "TFX1"(4) | formatVersion:UInt16=1 | schemeId:UInt16=1
                | keyCount:UInt32 | postingCount:UInt32
BODY: keyCount 个 KeyRecord, key 严格升序:
  keyLen:UInt8 | keyBytes(ASCII a-z) | postingCount:UInt16
  | postingCount 个: wordLen:UInt8 | wordBytes(UTF-8) | logFreq:Float32   (按 rawCount 降序)
```
> 所有多字节字段用 `loadUnaligned(fromByteOffset:as:)`（变长 key/word 破坏对齐，
> 普通 `load` 会 trap）。`wordLen` 是 **UTF-8 字节数**不是字符数。别再排序。

```swift
public struct LexiconPosting: Sendable, Equatable { public let word: String; public let logFreq: Float }

public enum LexiconBlobFormat {
    public static let magic: [UInt8] = Array("TFX1".utf8)
    public static let supportedFormatVersion: UInt16 = 1
    public enum ParseError: Error, Equatable {
        case badMagic, unsupportedFormatVersion(UInt16), schemeMismatch(expected: UInt16, found: UInt16), truncated }
    public struct Header: Sendable, Equatable {
        public let formatVersion: UInt16; public let schemeId: UInt16
        public let keyCount: UInt32; public let postingCount: UInt32 }
    public static func parseHeader(_ data: Data, expectedSchemeId: UInt16) throws -> Header
    public static func parse(_ data: Data, expectedSchemeId: UInt16) throws -> [String: [LexiconPosting]]
}

public final class LexiconStore: Sendable {
    public static func loadBundled(scheme: SchemeDefinition) throws -> LexiconStore   // Bundle.module/lexicon.bin
    public init(data: Data, scheme: SchemeDefinition) throws                          // 测试用 fixture
    public func postings(forKey key: String) -> [LexiconPosting]                      // base only; [] if none
    public var keyCount: Int { get }
    public var maxSyllables: Int { get }                                              // = max keyLen/2
}
```

**多音字修正数据源**（must_fix #2，correctness-critical）：blob 每字只存**首读音**
（8,624 个多音字），会让 D12 门 false-reject 掉正好要接受的 的/地/得 类修正。修法：
`build_lexicon.py` **增补侧车 `readings.bin`（TFXR v1）**——把 `pinyin.txt` 里每个单字的
**全部**无调读音编成 `[Character:[String]]`。Core 用它构建唯一的重拼音索引：

```
TFXR HEADER (12B, LE): magic "TFXR"(4) | version:UInt16=1 | charCount:UInt32 | reserved:UInt16
BODY: charCount 个: charUTF8Len:UInt8 | charUTF8 | readingCount:UInt8
      | readingCount 个: readingLen:UInt8 | reading(ASCII 无调拼音)
```

```swift
public struct PinyinReadingIndex: Sendable {                    // 唯一重拼音数据源
    public static func loadBundled() throws -> PinyinReadingIndex           // readings.bin
    public init(map: [Character: [String]])
    public func readings(of ch: Character) -> [String]           // 全部无调读音; [] = 未知(保守拒绝)
    /// 每字取任一合法读音后, 该 text 能否读成 codes(拼接小鹤码). 处理多音字: 只要存在一组读音组合匹配即真。
    public func canRead(_ text: String, asShuangpinCodes codes: String, decoder: ShuangpinDecoder) -> Bool
    public func isAllHanzi(_ text: String, allowing punctuation: Set<Character>) -> Bool
}
```

### 2.3 引擎结果 + 候选 + 覆盖层（TypoFreeCore/Engine, Overlay）— must_fix #5/#8

**唯一引擎入口 + 唯一结果类型**，是三份设计的**超集**：既带 slot#1 门控字段
（`hanziCount`/`endsAtClauseBoundary`），又带 learning 需要的 `bestPath:[WordSpan]`，
又带 IMK 需要的 `preeditDisplay`/`preeditCursor`。`convert` **必须**接受 boost overlay。

```swift
public enum CandidateSource: Sendable, Equatable { case base, userOverlay, fallback }
public struct WordSpan: Sendable, Equatable {          // learning 需要的 per-word (word,code)
    public let word: String; public let code: String   // code = 拼接小鹤码, 与 blob key 同格式
    public let range: Range<Int>                        // 音节索引区间 [i,j)
    public var syllableCount: Int { range.count }
}
public struct Candidate: Sendable, Equatable, Identifiable {   // 唯一 Candidate 类型
    public let id: Int
    public let word: String; public let code: String
    public let syllableCount: Int; public let score: Double
    public let source: CandidateSource
}
public struct EngineResult: Sendable, Equatable {      // 唯一结果类型 (超集)
    public let syllables: [Syllable]
    public let engineBest: String            // slot#2 — 1-best 整句 Viterbi
    public let bestPath: [WordSpan]          // 逐词, 供 learning keySeq 归因
    public let focus: Int
    public let focusCandidates: [Candidate]  // slot#3+
    public let incompleteTail: String?
    public let preeditDisplay: String        // 内联 marked text (见 §5 / user-Q3)
    public let preeditCursor: Int
    public let hanziCount: Int               // LLM ≥4 门
    public let syllableCount: Int
    public let endsAtClauseBoundary: Bool    // LLM 立即触发 (跳过防抖)
}

// 覆盖层: 不可变 snapshot, 由 learning loop 原子换入 (must_fix #8 决定: 不可变换入, 非锁)
public struct UserBoostOverlay: Sendable, Equatable {
    public let boosts: [String: [String: Float]]   // code → word → 【加性】log-boost delta
    public init(boosts: [String: [String: Float]])
    public static let empty = UserBoostOverlay(boosts: [:])
}

public struct LatticeConfig: Sendable {
    public var lengthBonusPerSyllable: Double = 2.0   // UX 载重常量, 需真打字校准
    public var floorLogFreq: Double = -1.0            // 合成兜底边 (< 任何真 ln(1+count)≥0)
    public var maxSpanSyllables: Int = 8
    public var maxCandidateSyllables: Int = 4
    public var minCharsForLLM: Int = 4
    public var clauseBoundary: Set<Character> = ["，","。","！","？","、","；","：",",",".","!","?"]
    public init()
}

public struct ConversionEngine: Sendable {
    public let scheme: SchemeDefinition
    public let decoder: ShuangpinDecoder
    public let lexicon: LexiconStore
    public let config: LatticeConfig
    public init(lexicon: LexiconStore, scheme: SchemeDefinition, config: LatticeConfig)
    /// 每键全量重算, 纯/同步(sub-ms). overlay 必传(可 .empty). 满足 must_fix #8。
    public func convert(_ keys: String, overlay: UserBoostOverlay, focus: Int) -> EngineResult
    /// UI 移动 focus 时便宜重查 slot#3+ (不重 decode/Viterbi)
    public func candidates(at focus: Int, syllableCodes: [String], overlay: UserBoostOverlay) -> [Candidate]
}
```

**Wire 协议 `CandidateEngine`**（app-shell 消费）现在带 overlay（修 must_fix #3 里
"overlay 到不了 lattice" 的漏洞）：
```swift
@MainActor public protocol CandidateEngine: AnyObject {
    func recompute(rawKeys: String, overlay: UserBoostOverlay) -> EngineResult
}
```

**Viterbi**：节点=音节位置 0…N；边=每个有词条的 span `[i,j)`，权 =
`bestBoostedLogFreq + lengthBonus(j-i)`，`lengthBonus(len)=config.lengthBonusPerSyllable*(len-1)`。
无词结尾处有合成单音节兜底边（score=floorLogFreq），保证连通、typo 输入也出路径。
Tie-break 全局统一：`(score desc, logFreq desc, len desc, word 字典序 asc)` → 可复现。
`overlay` 上的 boost = **加性** delta 叠加到 base logFreq。20 音节最坏 ≈160 lookups + O(N) DP，sub-ms。

### 2.4 LLM 修正层 — must_fix #3/#4

**唯一 `LLMCorrectionProvider` 协议**（四份收敛）。契约锁死：
- **provider 返回 RAW/未校验文本**，`nil = 声明放弃`（不可用/超时/取消/失败）。
  **NullProvider 返回 nil，不返回 engineBest**。
- **D12 门在 coordinator 里跑一次**（不是每个 provider 内部），backend 无关。
- provider 必须 **nonisolated 或 actor**，且**首个 await 之前不做重活**（威胁模型见 §3）。

```swift
public enum LLMBackendID: String, Sendable, CaseIterable { case foundationModels, mlx, null }
public enum LLMProviderAvailability: Sendable, Equatable {
    case ready                          // FM 可用 / MLX 已载
    case availableOnDemand              // MLX 已缓存未载, 首次 correct 时载
    case needsDownload(bytes: Int64?)   // MLX 权重缺, 首启下载
    case unavailable(reason: String)
}
public struct CorrectionRequest: Sendable, Equatable {   // 唯一 request
    public let id: UInt64                // 单调; 取消 + 排序 + staleness token
    public let precedingContext: String  // 已 secure-field 排除 + 截断
    public let rawPinyin: String         // 用户实敲的拼接小鹤码 (D12 门锚点)
    public let engineBest: String        // 确定性 1-best (兜底 + 修正主体)
    public let maxNewTokens: Int         // min(80, engineBest.count*2 + 8)
    public init(id: UInt64, precedingContext: String, rawPinyin: String, engineBest: String, maxNewTokens: Int)
}
public struct CorrectionResult: Sendable, Equatable {    // 唯一 result — provider 产 RAW
    public let text: String              // 原始模型串 (未过门)
    public let backend: LLMBackendID
}
public protocol LLMCorrectionProvider: Sendable {        // 唯一协议; 所有实现 off-MainActor
    nonisolated var id: LLMBackendID { get }
    func availability() async -> LLMProviderAvailability
    func prewarm() async
    func correct(_ request: CorrectionRequest) async -> CorrectionResult?   // nil = 放弃; 返回 RAW
    func releaseResources() async
}
public struct NullProvider: LLMCorrectionProvider {
    public nonisolated let id: LLMBackendID = .null
    public init()
    public func availability() async -> LLMProviderAvailability { .ready }
    public func prewarm() async {}
    public func correct(_ request: CorrectionRequest) async -> CorrectionResult? { nil }  // Cand#1 = engineBest
    public func releaseResources() async {}
}
```

**D12 门 = 唯一 `CorrectionValidator`**（must_fix #2 数据源修好后）。比较空间统一为
**codes**（拼接小鹤码，D12 门锚 `request.rawPinyin`），用 `PinyinReadingIndex.canRead`
接受**任一合法读音**（多音字安全），长度 ±1，全汉字。

```swift
public struct CorrectionConfig: Sendable {
    public var maxLengthDelta: Int = 1
    public var minHomophoneRatio: Double = 0.5      // D8 edit-ratio≤0.5 推导; 等长时
    public var allowedPunctuation: Set<Character> = ["，","。","！","？","、","；","："]
    public init()
}
public struct CorrectionValidator: Sendable {
    public let index: PinyinReadingIndex
    public let decoder: ShuangpinDecoder
    public init(index: PinyinReadingIndex, decoder: ShuangpinDecoder)
    /// 通过则返回 trim 后的接受串; 否则 nil (caller 静默回落 engineBest)。
    /// 顺序: 非空 → 全汉字(去允许标点) → 长度±1 → 逐字 canRead(任一读音)命中率≥ratio。
    public func validate(_ result: CorrectionResult, against req: CorrectionRequest,
                         config: CorrectionConfig = .init()) -> String?
}
```

**唯一异步编排 = `CorrectionCoordinator`（actor，住 Core）**（must_fix #4）。防抖/取消/门
都在这；**InputSession 不再自持 gen-token + Task.sleep**。唯一 staleness token = `requestID`，
在 MainActor apply 那一跳比对。

```swift
public struct CompositionSnapshot: Sendable {
    public let requestID: UInt64
    public let precedingContext: String   // MainActor 用快 IMKTextInput 路径同步取好 (见 §4)
    public let rawPinyin: String
    public let engineBest: String
    public let endedClause: Bool
    public let hanziCount: Int
}
public struct CorrectionEvent: Sendable {
    public let requestID: UInt64
    public let engineBest: String
    public let corrected: String?         // nil ⇒ slot#1 保持 engineBest
    public let backend: LLMBackendID
}
public actor CorrectionCoordinator {
    public init(provider: any LLMCorrectionProvider, validator: CorrectionValidator,
                config: LatticeConfig = .init(),
                debounce: Duration = .milliseconds(500),
                clock: any Clock<Duration> = ContinuousClock())
    /// 每次组合变化调用: 先取消上一在飞 → 满足触发(≥4 汉字 / clause boundary / 防抖) 则调 provider
    /// → 过 validator → 只 emit == 最新 requestID 的结果。
    public func onCompositionChanged(_ s: CompositionSnapshot)
    public func cancelPending()
    public func prewarm() async
    public func setProvider(_ p: any LLMCorrectionProvider) async   // 热切换; 先 releaseResources() 旧
    public nonisolated var events: AsyncStream<CorrectionEvent> { get }  // slot#1 单消费者订阅
}
```

**FoundationModelsProvider（Core，弱依赖，dev box 盲设计）**：
```swift
#if canImport(FoundationModels)
import FoundationModels
@available(macOS 26.0, *) @Generable struct Correction {
    @Guide(description: "修正后的中文句子: 同长同义, 只改同音/错别字, 只输出句子本身") var text: String }
@available(macOS 26.0, *) public actor FoundationModelsCorrectionProvider: LLMCorrectionProvider {
    public nonisolated let id: LLMBackendID = .foundationModels
    public init(promptBuilder: CorrectionPromptBuilder = .init(), timeout: Duration = .seconds(5))
    public static func isSystemAvailable() -> Bool { SystemLanguageModel.default.isAvailable }
    public func availability() async -> LLMProviderAvailability   // 映射 SystemLanguageModel.default.availability
    public func prewarm() async                                   // LanguageModelSession(instructions:).prewarm()
    public func correct(_ req: CorrectionRequest) async -> CorrectionResult?  // @Generable + timeout race → RAW
    public func releaseResources() async {}                       // XPC, 本进程 ~0MB
}
#endif
```

**MLXProvider（TypoFreeLLM，PRIMARY，dev box 全可测）**：runner 藏在 `CorrectionModelRunner`
端口后，状态机/闲卸/防抖用 `FakeModelRunner` 零权重单测；真实 MLX 走 1 个集成测试。
```swift
public enum MLXModelState: Sendable, Equatable {
    case unloaded, downloading(fraction: Double), loading, ready, unloading, failed(reason: String) }
public protocol CorrectionModelRunner: Sendable {
    func load(progress: @Sendable @escaping (Double) -> Void) async throws
    func run(request: CorrectionRequest, systemInstructions: String, userPrompt: String) async throws -> String
    func unload() async
    var isLoaded: Bool { get async }
    func availabilityProbe() async -> LLMProviderAvailability
}
public struct MLXQwenRunner: CorrectionModelRunner {   // Qwen3-0.6B-4bit, enable_thinking:false, temperature 0
    public init(downloader: any Downloader = TypoFreeModelDownloader(), gpuCacheLimitBytes: Int = 32*1024*1024)
}
public actor MLXCorrectionProvider: LLMCorrectionProvider {
    public nonisolated let id: LLMBackendID = .mlx
    public init(runner: any CorrectionModelRunner = MLXQwenRunner(),
                promptBuilder: CorrectionPromptBuilder = .init(),
                idleUnload: Duration = .seconds(12*60), perCorrectionTimeout: Duration = .seconds(2),
                clock: any Clock<Duration> = ContinuousClock())
    public var state: MLXModelState { get async }
    // 单 loadTask 合并并发载; correct 结束 arm idleTask; loadIfNeeded 入口查 lastUsed 双保险(睡眠冻结 timer)
}
public actor MLXModelManager {   // scaffold 命名保留; 内含 MLXQwenRunner + Application Support 缓存
    public init(modelID: String = "mlx-community/Qwen3-0.6B-4bit", cacheDirectory: URL,
                mirrorHost: String = "hf-mirror.com", idleTimeout: Duration = .minutes(12))
    public private(set) var state: MLXModelState
    public func acquireSession(progress: (@Sendable (Double) -> Void)?) async throws -> ChatSession
    public func unloadIfIdle() async
    public var isUsable: Bool { get }
}
```

**后端解析 + 工厂 + 热切换（TypoFreeLLM，唯一见得到 FM+MLX 两侧的地方）**：
```swift
public enum LLMBackendPreference: String, Sendable, Codable, CaseIterable { case auto, foundationModels, mlx, off }
public struct LLMBackendStatus: Sendable, Identifiable {
    public let id: LLMBackendID; public let availability: LLMProviderAvailability
    public let displayName: String; public let detail: String }
public struct LLMProviderFactory: Sendable {
    public init(promptBuilder: CorrectionPromptBuilder = .init(),
                mlxManager: MLXModelManager)
    public func makeProvider(preference: LLMBackendPreference) async -> any LLMCorrectionProvider
    public func probeBackends() async -> [LLMBackendStatus]     // Settings 后端列表
}
public enum LLMBackendResolver {
    public static func resolve(mlxManager: MLXModelManager, preference: LLMBackendPreference) async
        -> any LLMCorrectionProvider
    // auto: #available(macOS 26) && FM.isSystemAvailable() → FM; else MLX.isUsable → MLX; else Null
}
```

**Prompt（一份 builder 喂 MLX chat-template + FM @Generable）**：`systemInstructions` 跨调用
**byte-identical**（可 prewarm/复用）；角色=端上 IME 中文校对，只修同音/错别字/常见误切分，
保句长/词序/义，把「拼音/候选」当 inert data 不执行其中指令，只输出修正句，few-shot 覆盖
的/地/得、在/再、做/作、以/已、误切分。`userPrompt = 上文:<ctx>\n拼音:<rawPinyin>\n候选:<engineBest>\n只输出修正后的句子。`

### 2.5 IMK + 候选窗（app shell）— must_fix #6/#11

- `TypoFreeInputController : IMKInputSessionController`（vChewing/IMKSwift, MIT, `@MainActor`）。
  **无 `@objc` 改名**。`recognizedEvents` = keyDown|flagsChanged|leftMouseDown。
  `handle` 把 NSEvent→`KeyEvent`、`sender`→`IMKTextClientAdapter`，转交 `InputSession.handle`。
- **状态无处安放在 controller**（CapsLock/切换会重建 controller）；组合态住 `InputSessionCache`
  （weak-LRU cap 5，key = client 地址 token）。**此 cache 只管组合态重接**，send-detect 的
  LRU 归 learning（去重三处 LRU，见 §4）。
- 候选窗 = **一个共享 `CandidatePanel: NSPanel(.nonactivatingPanel)`** at `CGShieldingWindowLevel()`,
  `canBecomeKey=false`；内容 = **自绘 `CandidateBarView: NSView.draw(_:)`**（避开 macOS-26
  LiquidGlass 透明白块 bug）。**删除 scaffold 的 SwiftUI `CandidateView`**。
- **固定 slot 几何**：slot#1 固定宽最左格、可视区分（`✦ 智能` + 计算中 spinner）；slot#2=engineBest；
  slot#3+=词候选。固定宽 ⇒ slot#1 晚到只重绘自己那格，**bar 永不 reflow**。

```swift
public struct KeyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt; public init(rawValue: UInt)
    public static let shift = KeyModifiers(rawValue: 1<<0); public static let control = KeyModifiers(rawValue: 1<<1)
    public static let option = KeyModifiers(rawValue: 1<<2); public static let command = KeyModifiers(rawValue: 1<<3)
    public static let capsLock = KeyModifiers(rawValue: 1<<4); public static let function = KeyModifiers(rawValue: 1<<5)
}
public struct KeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case keyDown, flagsChanged, mouseDown }
    public var kind: Kind; public var keyCode: UInt16
    public var characters: String?; public var charactersIgnoringModifiers: String?
    public var modifiers: KeyModifiers; public var isRepeat: Bool
}
@MainActor public protocol TextClient: AnyObject {
    func commit(_ text: String); func setPreedit(_ composing: String, cursor: Int); func clearPreedit()
    func caretRectInScreen() -> CGRect
    var bundleIdentifier: String? { get }; var processIdentifier: pid_t { get }; var addressToken: Int { get }
}
public enum Slot1State: Sendable, Equatable {
    case computing(provisional: String)   // spinner + engineBest
    case landed(corrected: String)        // ✦
    case unavailable                      // Null/absent → engineBest, 无标记
}
public struct CandidateBarModel: Sendable, Equatable {
    public var slot1: Slot1State; public var engineBest: String
    public var words: [Candidate]; public var highlighted: Int
    public func commitText(atSlot i: Int) -> String?      // 1→recommended, 2→engineBest, 3+→words
    public var recommendedCommitText: String { get }       // landed correction ?? engineBest
}
@MainActor public protocol CandidateRendering: AnyObject {
    func show(_ model: CandidateBarModel, at caret: CGRect)
    func updateSlot1(_ state: Slot1State)   // 原地重绘, 不 reflow
    func moveHighlight(to index: Int); func hide(); var isVisible: Bool { get }
}
```

### 2.6 InputSession 状态机（Core/Session, @MainActor, IMK-free）— must_fix #4/#7

事件路由（中文模式、非 Command）：`a–z`→追加+重算+`scheduleCorrection`；`1–9`→选候选
commit；`Space`→显式接受 commit `recommendedCommitText`；`Return`→verbatim commit rawBuffer；
`Backspace`→删末键重算/清空隐藏；`Escape`→清空取消；`Command+*`→隐式 finalize(engineBest) 后
passthrough。`.flagsChanged` 孤 Shift → 中英切换。`.leftMouseDown` → 隐式 finalize。

**commit 内容模型**（一条一致规则）：显式接受→`recommendedCommitText`（landed 修正 ?? engineBest）；
隐式 finalize（commitComposition/deactivate/鼠标移开/Command）→**只 engineBest，永不未接受的异步修正**；
Return→verbatim rawBuffer。**每次 commit** 都：清 buffer、bump requestID（作废在飞 LLM）、隐藏 panel、
调 `commitObserver.didCommit(...)`。

**commit 契约携带 learning 需要的一切**（must_fix #7）：
```swift
@MainActor public protocol CommitObserver: AnyObject {
    /// 携带 per-word WordSpan(engine.bestPath)、LearningSessionID、commit 时抓的 ContextSnapshot(含 pollTarget)。
    func didCommit(committed: String, spans: [WordSpan], sessionID: LearningSessionID, snapshot: ContextSnapshot)
    func sessionDidEnd(sessionID: LearningSessionID)
}
@MainActor public protocol ContextReading: AnyObject {           // 唯一 context 协议 (must_fix #6)
    /// LLM 路径: 只要 precedingContext(快 IMKTextInput 路径, sync-on-MainActor, <5ms)。
    func precedingContext(for client: (any TextClient)?, maxChars: Int) -> String
    var isSecureContext: Bool { get }
    /// commit 时抓完整 ContextSnapshot(before/after/fieldSignature/pollTarget), 供 learning + send-detect。
    func captureSnapshot(for client: (any TextClient)?) -> ContextSnapshot
}
@MainActor public struct SessionDependencies {
    public var engine: any CandidateEngine
    public var coordinator: CorrectionCoordinator?        // nil ⇒ Null-only, 无异步 slot#1
    public var context: any ContextReading
    public var renderer: any CandidateRendering
    public weak var commitObserver: (any CommitObserver)?
    public var overlayProvider: @MainActor () -> UserBoostOverlay   // 读当前不可变 overlay snapshot
}
@MainActor public final class InputSession {
    public init(dependencies: SessionDependencies, sessionID: LearningSessionID)
    public func attach(client: any TextClient)
    public func detach()
    @discardableResult public func handle(_ key: KeyEvent) -> Bool
    public func finalizeImplicitly()      // commit engineBest
    public func cancelComposition()
    public func sessionWillEnd()
    public private(set) var rawBuffer: String
    public private(set) var englishMode: Bool
    public private(set) var isComposing: Bool
    // 内部: recomputeAndRender() 同步; scheduleCorrection() 建 CompositionSnapshot 交 coordinator;
    //       订阅 coordinator.events, apply 时比对 requestID (唯一 staleness token)。不再自持 Task.sleep/gen-token。
}
```

### 2.7 上下文 + 学习（Core 纯逻辑 + app-shell 真实 AX）— must_fix #6

**Core 侧（纯，无 AX import）**：
```swift
public struct RoundedFrame: Equatable, Hashable, Sendable { public let x,y,width,height: Int; public init(rect: CGRect) }
public struct FieldSignature: Equatable, Hashable, Sendable {
    public let bundleId: String; public let pid: pid_t?; public let role: String?
    public let subrole: String?; public let roundedFrame: RoundedFrame? }
public enum ContextSourceTier: String, Sendable { case imkTextInput, accessibility, sentenceOnly }
public enum CaptureSuppressionReason: String, Sendable { case none, denylisted, systemSecureInput, secureField, noSourceAvailable }
public struct ContextSnapshot: Sendable {   // pollTarget(AXUIElement/IMKTextInput) 只在 app-shell 子类型携带
    public let before: String; public let after: String
    public let appBundleId: String?; public let fieldSignature: FieldSignature?
    public let sourceTier: ContextSourceTier; public let suppressionReason: CaptureSuppressionReason
}
public enum SecureFieldGuard {   // 纯字符串逻辑, 可单测无需 live AX
    public struct Markers: Sendable { public let role, subrole, roleDescription, title, descriptionLabel: String? }
    public static func isSystemSecureInputActive() -> Bool   // 包 Carbon IsSecureEventInputEnabled()
    public static func isSensitiveElement(_ m: Markers) -> Bool
    // 短 token(pin/otp/ssn/cvv/cvc) 整词边界匹配 (防 "opinion"/"Pinyin" 误判); 长 token substring
}
public struct SendDetectionSession: Sendable {   // 纯状态机, app-shell 喂快照
    public enum Transition: Sendable, Equatable { case unchanged, textChanged(String), sessionEnded }
    public init(signature: IdentitySignature, text: String)
    public mutating func poll(signature: IdentitySignature?, newText: String?) -> Transition
    // "元素解析失败" == "读到空串" == session end (D7, newText:nil)
}
```

**app-shell 侧（真实 AX，唯一 import ApplicationServices）**：`ContextReadLadder`
（IMKTextInput→AX→sentence-only）、`AXFocusResolver`（`AXUIElementCreateSystemWide` +
50ms `AXUIElementSetMessagingTimeout`，owner 用 `AXUIElementGetPid` 非 frontmost）、
`SendDetectionPoller`（持 commit 时抓的 `AXUIElement`/`IMKTextInput` 引用，1.5s 轮询，
仅当有未 flush 会话时起 timer）。denylist 默认只 `com.apple.Terminal`/`com.googlecode.iterm2`。

**学习（Core 纯 + userdict）**：Myers diff（stdlib `CollectionDifference`）→ 编辑脚本分组 →
会话级拒绝门（`editRatio>0.5 || lengthDelta>0.6` 丢弃；`old.count≤4` 豁免全局门，直接逐 op
分类，救的/地单字换）→ 逐 op 分类（同长 + ≤4 字 + `PinyinReadingIndex` 无调读音交集≠∅ →
CorrectionCandidate；insert ≤6 字 + `encode(tonelessSyllables:)` 成功 → OOVCandidate）→
occurrence≥2 才影响排名。span 存 ≤20 字。

```swift
public struct CommittedSpan: Equatable, Sendable {
    public let range: Range<Int>; public let keySeq: String; public let word: String }
public struct LearningSessionID: Hashable, Sendable { public init(owner: AnyObject) }
public protocol Repinyinizer: Sendable { func tonelessReadings(for text: String) -> Set<[String]> }  // 由 PinyinReadingIndex 适配
public enum DiffLearner {   // 纯静态
    public struct CorrectionCandidate: Equatable, Sendable { public let keySeq, wrong, right: String; public let contextPinyin: [String] }
    public struct OOVCandidate: Equatable, Sendable { public let keySeq, word: String }
    public enum RejectReason: Equatable, Sendable { case editRatio(Double), lengthDelta(Double), emptyBase, emptyFinal }
    public struct Outcome: Equatable, Sendable { public let corrections: [CorrectionCandidate]; public let oovCandidates: [OOVCandidate]; public let rejected: RejectReason? }
    public static func evaluate(committedSpans: [CommittedSpan], finalFieldValue: String,
                                repinyinizer: any Repinyinizer, encoder: ShuangpinDecoder) -> Outcome
}
@MainActor public final class LearningLoopCoordinator {   // 唯一 send-detect + LRU 归属者 (must_fix, 去重三处)
    public init(store: UserDictStore, overlayHost: OverlayHost, repinyinizer: any Repinyinizer,
                encoder: ShuangpinDecoder, pollInterval: TimeInterval = 1.5, sessionCap: Int = 5)
    public func recordCommit(sessionID: LearningSessionID, spans: [WordSpan], snapshot: ContextSnapshot,
                             pollTarget: SendDetectionPollTargetRef)
    public func sessionWillEvict(_ id: LearningSessionID)
    public func discardSession(_ id: LearningSessionID)   // secure-field 中途触发
    public var isPolling: Bool { get }
}
```

### 2.8 userdict（Core/UserDict）— must_fix #10：原生 sqlite3，**弃 GRDB**

`~/Library/Application Support/com.soleilyu.inputmethod.TypoFree/userdict.sqlite`（WAL）。4 表：
`words(key_seq,word,boost,count,last_used)`、`correction_pairs`、`pending_oov`、
`learning_events(span≤20)`。occurrence≥2 → 促进 `words`，`boost = log(1+count)`（加性 log-domain，
直接叠进 Viterbi）。`clearAllLearnedData()` 删全表 + WAL checkpoint + VACUUM（无取证残留）。

```swift
public actor UserDictStore {   // 唯一 sqlite 句柄持有者 (单写者 WAL)
    public static func applicationSupportDefault(bundleID: String) -> URL
    public init(fileURL: URL) throws
    /// 启动一次; 结果交给 OverlayHost 建首个不可变 UserBoostOverlay。
    public func loadBoostOverlay() throws -> [String: [String: Float]]   // code→word→boost delta
    @discardableResult public func recordCorrection(_ c: DiffLearner.CorrectionCandidate) throws -> BoostUpdate?
    @discardableResult public func recordOOV(_ c: DiffLearner.OOVCandidate) throws -> BoostUpdate?
    public func recordEvent(kind: LearningEventKind, appBundleId: String?, spanBefore: String?, spanAfter: String?) throws
    public func clearAllLearnedData() throws
}
public struct BoostUpdate: Sendable, Equatable { public let keySeq, word: String; public let boost: Double }
```

**Overlay 表征（must_fix #8 决议）**：**不可变 snapshot + 原子换入**（非锁 cache）。
`@MainActor OverlayHost` 持 `var current: UserBoostOverlay`；`UserDictStore` 每次 durable 写
产 `BoostUpdate` → 回 MainActor 上 `OverlayHost` 用 delta 重建并换入新 snapshot。热路径
`ConversionEngine.convert(overlay:)` 只读 `SessionDependencies.overlayProvider()`（MainActor 上
的一次引用读，lock-free）。
```swift
@MainActor public final class OverlayHost {
    public private(set) var current: UserBoostOverlay
    public init(initial: UserBoostOverlay)
    public func apply(_ update: BoostUpdate)     // 重建 + 原子换入
    public func replaceAll(_ overlay: UserBoostOverlay)
}
```

---

## 3. 并发契约（crown jewel）

**MainActor → off-MainActor → MainActor 铁律**：
1. **MainActor（同步，sub-ms）**：`InputSession.handle(key)` 追加 buffer →
   `engine.recompute(rawKeys:overlay:)`（decode+Viterbi，全量重算，纯）→ `client.setPreedit(...)` +
   `renderer.show(.computing(provisional: engineBest))`。**同步取 precedingContext 只用快
   IMKTextInput 路径（<5ms）**，深度 AX 读**不在热路径**（只在 commit 时为 learning 抓，off 重要窗口）。
   → **`handle` 立即返回 true**。
2. **off-MainActor（actor）**：`InputSession.scheduleCorrection` 建 `CompositionSnapshot` 交
   `CorrectionCoordinator`（actor）→ 防抖（`Task.sleep`）/取消在飞 → `provider.correct`（provider
   为 actor 或 nonisolated struct，`await` 自动跳出 MainActor，重活全在 provider 内）→
   `CorrectionValidator.validate`（纯）→ 只对 == 最新 requestID `yield CorrectionEvent`。
3. **回 MainActor**：`InputSession` 订阅 `coordinator.events`，apply 时**比对 requestID**
   （唯一 staleness token）；不符（用户已打字/commit/切窗）则丢弃；符则 `renderer.updateSlot1(.landed)`。

**取消 = 双保险**：新键/commit/deactivate 都 `coordinator.cancelPending()` **且** bump requestID
（协作式取消不保证底层推理立即中止，但 MainActor apply 那跳按 requestID 丢弃迟到结果）。

**provider 隔离硬契约**（deadlock 风险 #2）：任何 `LLMCorrectionProvider` 实现**必须**
nonisolated/actor，且**首个 `await` 前不做重活**。禁止 `@MainActor` provider。
CI 加断言：`correct()` 期间 MainActor 不被占用。

**AX 读不上热路径**（deadlock 风险 #1 修法）：LLM correction 只用 MainActor 上 <5ms 的
IMKTextInput this-sentence context；50ms AX 增强读只在 **commit 时**为 learning 抓（离热路径），
且 `AXUIElementSetMessagingTimeout` 硬顶 50ms。

**overlay 无锁**：热路径读不可变 snapshot 引用（§2.8）；写在 UserDictStore actor，产 delta 回
MainActor 换入。Core 里无锁、无 actor-per-keystroke。

---

## 4. Send-detection / 会话 LRU 归属（去三处重叠）

- **组合态重接**：`InputSessionCache`（app shell，weak-LRU cap 5，key=client 地址 token）——
  仅 CapsLock/切换重建 controller 后取回 `InputSession`。
- **send-detect + learning 会话**：`LearningLoopCoordinator`（Core，持 commit 时抓的 AX/IMK
  引用轮询，cap 5）——**唯一** send-detect 归属者。
- **删除** scaffold 的 `SendDetectionSession` 独立 `LearningSessionRegistry` 重复（`SendDetectionSession`
  纯状态机保留供 `LearningLoopCoordinator` 内部用）。
- **pollTarget 来源**：commit 时 app-shell 的 `IMKTextClientAdapter`/`AXFocusResolver` 构造
  `SendDetectionPollTargetRef`（持 live `IMKTextInput`/`AXUIElement`）交给 `recordCommit`——否则
  poller 无对象可轮。

---

## 5. 内联 preedit 契约（user-Q3，未锁 → 见 JSON open_questions）

`EngineResult.preeditDisplay/preeditCursor` 由引擎产。推荐默认 = **hybrid**：完整音节显示汉字 +
末尾未完成音节显示原始字母（主流双拼手感，同时让 slot#1 修正读作明显升级）。用户可换。

---

## 6. 隐私与安全

- context-capture + learning **默认全开**，secure-field 永远排除。
- **Secure-field 双保险**（OR）：动态 `IsSecureEventInputEnabled()`（每 poll tick 查，零 IPC，先查）
  + 静态 `SecureFieldGuard` 宽标记表（`AXSecureTextField` subrole 权威；否则 role/subrole/
  roleDescription/title/description 大小写不敏感扫；短 token 整词边界防 "Pinyin" 误判）。
  学习会话中途转 secure → 立即无条件丢弃已累积 span，不算 diff、不写表。
- learning 只存 ≤20 字 span，写边界强制截断；零遥测、全本地、不联网同步。
- 一键「清除学习数据」= 删全表 + WAL checkpoint + VACUUM。base 词库只读 blob，不动。
- Settings 隐私声明（day 1，中文）：明示本地保存路径、不上传/不联网/不遥测、密码框强制排除、
  清除不可逆。
- **denylist**：默认只 `com.apple.Terminal`/`com.googlecode.iterm2`（高置信）；反作弊游戏 bundle
  不猜测，用户可扩展（denylisted app 连 AX introspection 都不尝试）。

---

## 7. 设置与首运行 UX（must_fix #12 — 指派 owner）

| UX | Owner 文件 | 内容 |
|---|---|---|
| 后端选择 | `UI/BackendPickerView.swift`（Settings 内） | `LLMProviderFactory.probeBackends()` 列 FM/MLX/Off 状态；改选 → `coordinator.setProvider(factory.makeProvider(...))`（先释放旧 MLX 500MB） |
| MLX 下载进度 | `UI/ModelDownloadView.swift` | `MLXModelState.downloading(fraction)` 进度条 + 触发/取消 + 显示 HF/hf-mirror；~500-650MB |
| AX 权限流 | `UI/PermissionView.swift` + `Context/*` | `AXIsProcessTrustedWithOptions`(`kAXTrustedCheckOptionPrompt`) 触发系统弹窗；"未授权"态 + 授权后重查；核心打字**永不依赖 AX**，仅增强层 |
| 首装启用引导 | `UI/OnboardingView.swift` | 教用户：System Settings ▸ Keyboard ▸ Input Sources ▸ + 小鹤双拼；**首装必登出/登入一次** |
| 清除学习数据 | `UI/SettingsView.swift` | 调 `UserDictStore.clearAllLearnedData()` + 隐私声明 |
| 菜单栏后端指示 | `UI/MenuBarView.swift` | FM/MLX/Null glyph + 错误浮层（MLX 下载失败 / FM `.rateLimited`）|
| 错误浮层 | `MenuBarView` + `SettingsView` | MLX 双源都挂 → `.unavailable`；FM 背景 `.rateLimited` → 需可见状态，不再纯静默 |
| Scheme 选择 | 推迟（v1 只 flypy） | `SchemeDefinition.schemeId` 已留位；不假装已做 |
| 图标 | `Assets.xcassets` + `menuicon.tiff` | 待产（M8）|

**Info.plist 关键**（corrected against squirrel 真实 plist）：`LSUIElement=true` +
`LSBackgroundOnly=false` + `NSPrincipalClass=NSApplication`（EXPLORE Appendix C 的
`LSBackgroundOnly=true` 是错的）；`InputMethodConnectionName=$(PRODUCT_BUNDLE_IDENTIFIER)_Connection`；
`InputMethodServerControllerClass=$(PRODUCT_MODULE_NAME).TypoFreeInputController`；
`ComponentInputModeDict` 单模式 `com.soleilyu.inputmethod.TypoFree.mode.shuangpin`（`小鹤双拼`，`zh-Hans`）。
**entitlements 仅** `com.apple.security.app-sandbox=false`（AX 走 TCC 运行期授权，非 entitlement key）。

**dev.sh**（对齐 squirrel 机制，标准 `TIS*` API，安装到**每用户** `~/Library/Input Methods`，
无需 sudo）：build → `--quit` 旧实例 → 复制 bundle → `--register-input-source` →
`--enable-input-source` → `--select-input-source`。**首装仍需登出/登入**（`imklaunchagent`
无运行期 API 强制 rescan）；之后每次 rebuild `killall TypoFree` 热换。`make-dev-cert.sh` 造稳定
自签身份（ad-hoc `-` 每 build 变 cdhash 会重置 TCC/AX 授权）。

---

## 8. 词库与构建

**来源**（live 复验 2026-07-18，与 EXPLORE 同 commit）：essay.txt（rime-essay LGPL-3.0，
442,696 词+频）+ large_pinyin.txt（phrase-pinyin-data MIT）+ pinyin.txt（pinyin-data MIT，
44,435 字，8,624 多音）。

**实测覆盖**：解析 442,402/442,693 = **99.9343%**；未解析 291（260 拼音层稀有字/专名 +
31 flypy-encode 层 哟/唷/嗯 类叹词，标准小鹤无码）。

**blob 统计**：flypy key 310,752；postings 442,402；max key 38B（19 音节）；max word 57B；
单 key 最多 postings 359（"yi"）；logFreq [0.0, 15.3889]（`ln(1+rawCount)`）；`lexicon.bin` **8.67MB**；
构建确定性（两跑 byte-identical）；估算 Swift 常驻 ~36.2MB。

**正确性**：你好→`nihc`；8 陷阱两法验证（直接查表 + 真实字全流程 歪/位/弯/王/腰/有/阳/用）；
对照 rime-double-pinyin algebra 逐字符核过 r=uan / n=iao 例外。

**两处新增（must_fix + user-Q1）**：
1. **多音字侧车 `readings.bin`（TFXR v1）**——build_lexicon.py 增补，为 D12 门提供每字全部读音
   （blob 只存首读音，会 false-reject 的/地/得）。**这是 must_fix #2，M2 必做**。
2. **繁→简 OpenCC**（user-Q1，见 JSON）——essay.txt 繁体主导（說 340k vs 说 0；這 182k vs 这 0），
   小鹤是简体方案、dev box locale zh_CN。推荐 build 时加 `opencc-python-reimplemented`（Apache-2.0，
   已 smoke 测）在拼音解析前繁→简、同形合并频次。~30-60min 脚本改，非重构，**上线前必做**。

**license**：essay.txt LGPL-3.0（bundle 编译 blob + 保持 build 脚本开放 + Settings/About 署名，
逐字文本在 `data/README.md`）；large_pinyin/pinyin MIT（仅署名）。build_lexicon.py 原创。

---

## 9. 测试策略

**TypoFreeCore（`swift test`，确定性，CI-able，零网络/零 Metal）**：
- 8 陷阱 + 常规对照 + 重载键（o/k/l/s/x/v/t）+ r/n 条件例外 + 压缩声母 + 反向 encode 往返。
- 两层词库：`Fixtures/mini-lexicon.bin`（手写小 TFX1）+ `LexiconStoreRealBlobTests`（真 `lexicon.bin`
  符号链接，断言 `postings("aa")==[啊,阿,錒,嗄,锕]` 顺序、载入时间预算）+ `readings.bin` 覆盖断言。
- Viterbi：短语胜单字（选好频率让 你好 赢）/ 稀有短语让位单字 / tie-break 确定 / 非法音节兜底连通 /
  **overlay 加性 boost 进 lattice**（must_fix #8 回归）。
- D12 门：接受同音 / 拒 latin 前缀 / 拒长度漂移 / 拒幻觉 / **多音字不误拒**（得 děi、地 dì）。
- `CorrectionCoordinator`：防抖只调一次 / clause boundary 跳防抖 / 新键取消旧 / stale-drop 按 requestID /
  超时→nil→engineBest / 卡死 provider 不死锁。全用 `FakeModelRunner`/fake provider，**零 FM/零 MLX**。
- `MyersDiff`/`DiffLearner`：≤4 豁免救单字换 / editRatio 拒 / lengthDelta 边界(0.6 过、0.7 拒) /
  OOV 零声母陷阱 keySeq(外→wd、王→wh)。
- `UserDictStore`：occurrence<2 不影响、==2 促进 boost=log(1+count) / clearAll / 并发 recordOccurrence 不坏 WAL。
- `SecureFieldGuard`：`AXSecureTextField`真 / "one-time code"真 / "Opinion"假 / "Pinyin"假 / "search field"假。
- `SendDetectionSession`：unresolved==empty==sessionEnded。
- `FoundationModelsProvider` dev box 只编译期覆盖（`.unavailable(.appleIntelligenceNotEnabled)`），
  运行期烟测断言 coordinator 静默回落 engineBest（验证"优雅缺席"契约）。

**TypoFreeLLM**：`LLMBackendResolverTests` fake 两分支（零网络）；
`MLXModelManagerLiveTests` 门控 `TYPOFREE_MLX_LIVE_TEST=1`（真下载 Qwen3-0.6B→temp App-Support 目录、
真 `ChatSession.respond`、断言 `additionalContext["enable_thinking"]==false` 无 `<think>`、延迟、非 nil）。

**app-shell 手动真机清单**（不可自动化）：dev.sh 装成功 → System Settings 加 → TextEdit 打字、
slot#2 即时 / slot#1 异步不卡 → Safari(contenteditable) / Messages 上下文 ladder 优雅退化 →
改字后 send-detect 学习记录并后续排名升 → 密码框仍打字但学习 inert → 清除学习数据 →
FM/MLX 人为不可用时菜单栏指示 + engineBest 仍出。

---

## 10. 两个早期 spike（DECISIONS §4，必须尽早去风险）

1. **FM 背景 `.rateLimited`**：最小 `IMKInputController` + FM harness 跑多小时背景 `respond()` →
   背景 app 会不会 `.rateLimited`？（若会，MLX-primary 已是对的选择——Q2 已定，此 spike 是确认。）
   核心打字（M0-M4）不依赖 FM。
2. **`imklaunchagent` 托管 bundle 在 `~/Library/Input Methods` 能否拿 AX/TCC 授权**：无参考 IME
   验证过每用户目录（squirrel/vChewing 都系统级 `/Library`）+ ad-hoc 签名每 build 重置 TCC。
   M5/M6 必做；核心打字按构造不依赖 AX，blast radius 只限增强层。

---

## 11. 参考与 License

- **vChewing/IMKSwift**（MIT，tag `26.06.02`）：`IMKInputSessionController`。年轻、单维护者，钉 tag。
- **ml-explore/mlx-swift-lm**（MIT，钉 `2.31.3`，2.x 末线）：`ChatSession`/`LLMModelFactory`。
  3.x 破坏性 API 分裂（2026-07-17），升级前重验 Downloader/TokenizerLoader 迁移。
- **huggingface/swift-transformers**（MIT/Apache，`1.2.0`）：`HubApi`（`downloadBase`→App Support，
  非默认 Caches）。
- **FoundationModels**（系统 framework）：`SystemLanguageModel`/`@Generable`/`LanguageModelSession`。
- **rime/squirrel**（GPLv3，**只读机制不抄代码**）：`TIS*` 安装/重载形状 + Info.plist 校正。
- **wispr**（Apache-2.0，任务形状）：timeout-race 静默回落。
- 词库：essay.txt LGPL-3.0、large_pinyin/pinyin MIT（详见 `data/README.md`，必复制进 About）。
```
