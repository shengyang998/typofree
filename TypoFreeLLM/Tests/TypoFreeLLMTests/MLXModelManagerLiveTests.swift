import XCTest
@testable import TypoFreeLLM
import TypoFreeCore

/// M4 (DESIGN.md §2.4/§9) — the ONE real-MLX integration test, gated behind
/// `TYPOFREE_MLX_LIVE_TEST=1`. It really downloads Qwen3-0.6B-4bit (HF →
/// hf-mirror fallback) into a temp Application-Support-style dir and runs a real
/// correction. NOT part of the CI gate (network + ~400 MB + minutes).
final class MLXModelManagerLiveTests: XCTestCase {

    func testRealDownloadAndInferenceHasNoThinkLeak() async throws {
        guard ProcessInfo.processInfo.environment["TYPOFREE_MLX_LIVE_TEST"] == "1" else {
            throw XCTSkip("set TYPOFREE_MLX_LIVE_TEST=1 to run the real MLX download + inference test")
        }

        // enable_thinking must be OFF (asserted at the config level too, so this
        // holds even when the gated download is skipped).
        XCTAssertEqual(MLXModelManager.thinkingDisabledContext["enable_thinking"] as? Bool, false)

        // Operators can point at a pre-seeded cache (app-cache layout
        // `<dir>/models/mlx-community/Qwen3-0.6B-4bit/`) to skip the download.
        let cacheDir = ProcessInfo.processInfo.environment["TYPOFREE_MLX_CACHE_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? LLMTestFixtures.tempCacheDir()
        let manager = MLXModelManager(cacheDirectory: cacheDir)
        let builder = CorrectionPromptBuilder()
        // "他明天来我加吃饭" → expect "他明天来我家吃饭" (加→家) after the gate.
        let req = CorrectionRequest(id: 1, precedingContext: "周末安排",
                                    rawPinyin: "", engineBest: "他明天来我加吃饭")

        let start = Date()
        let raw = try await manager.run(request: req,
                                        systemInstructions: builder.systemInstructions,
                                        userPrompt: builder.userPrompt(for: req))
        let elapsed = Date().timeIntervalSince(start)
        print("‼️ [M4 live] MLX raw=\(raw.debugDescription) firstResponse=\(String(format: "%.1f", elapsed))s")

        XCTAssertFalse(raw.isEmpty, "model produced no output")
        XCTAssertFalse(raw.contains("<think>"), "enable_thinking:false must suppress <think> tokens")
        XCTAssertFalse(raw.contains("</think>"))

        // Second call to measure steady-state latency (weights already loaded).
        let t2 = Date()
        _ = try await manager.run(request: CorrectionRequest(id: 2, precedingContext: "",
                                                             rawPinyin: "", engineBest: "今天天气很好"),
                                  systemInstructions: builder.systemInstructions,
                                  userPrompt: builder.userPrompt(for: CorrectionRequest(
                                      id: 2, precedingContext: "", rawPinyin: "", engineBest: "今天天气很好")))
        print("‼️ [M4 live] MLX steady=\(String(format: "%.1f", Date().timeIntervalSince(t2) * 1000))ms")

        await manager.unload()
        let loaded = await manager.isLoaded
        XCTAssertFalse(loaded)
    }
}
