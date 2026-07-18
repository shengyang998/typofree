import TypoFreeCore
import MLXLLM
import MLXLMCommon
// swift-transformers's "Transformers" product (declared as a dependency
// below, matching DESIGN.md §1 exactly) is an umbrella *product* that
// aggregates the `Tokenizers`/`Generation`/`Models` targets for linking —
// it is not itself an importable module. `import Tokenizers` pulls in one
// of those real targets and proves the same link path.
import Tokenizers

/// M0 scaffold placeholder.
///
/// TypoFreeLLM's real surface — `MLXModelManager`, `MLXQwenRunner`,
/// `MLXCorrectionProvider`, `LLMProviderFactory`, `LLMBackendResolver`
/// (DESIGN.md §2.4) — lands in M4 (tasks.md §M4). This file exists only to
/// give the M0 scaffold target buildable sources, and to prove
/// `mlx-swift-lm` + `swift-transformers` + `TypoFreeCore` all resolve and
/// link together on this toolchain (Xcode 26.4 / Swift 6.3) ahead of M4 —
/// that first resolve+compile of MLX from source is the slow part of M0
/// (5-15 min), not anything in this file itself.
public enum TypoFreeLLMScaffold {
    /// Trivial cross-module reference so `swift build` proves real linkage
    /// against `TypoFreeCore`, not just that the package graph resolves.
    public static func scaffoldSummary() -> String {
        let schemeId = FlypyScheme.flypy.schemeId
        return "TypoFreeLLM scaffold OK (Core schemeId=\(schemeId))"
    }
}
