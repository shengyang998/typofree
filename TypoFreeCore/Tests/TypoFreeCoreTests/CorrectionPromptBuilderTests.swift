import XCTest
@testable import TypoFreeCore

/// M4 (DESIGN.md §2.4, DECISIONS.md 2026-07-18) — `CorrectionPromptBuilder`
/// (v3 verbatim) + `CorrectionPostProcessor` (pre-gate normalization).
final class CorrectionPromptBuilderTests: XCTestCase {
    func testSystemInstructionsAreByteIdenticalAcrossInstances() {
        XCTAssertEqual(CorrectionPromptBuilder().systemInstructions,
                       CorrectionPromptBuilder().systemInstructions)
        XCTAssertEqual(CorrectionPromptBuilder().systemInstructions,
                       CorrectionPromptBuilder.defaultSystemInstructions)
    }

    /// The user turn matches the v3 python shape exactly (ends with "输出:").
    func testUserPromptShapeMatchesV3Verbatim() {
        let b = CorrectionPromptBuilder()
        let req = CorrectionRequest(id: 1, precedingContext: "周末安排",
                                    rawPinyin: "ta ming tian",
                                    engineBest: "他明天来我加吃饭")
        XCTAssertEqual(b.userPrompt(for: req),
                       "上文:周末安排\n拼音:ta ming tian\n候选:他明天来我加吃饭\n输出:")
    }

    /// Few-shot examples are real user/assistant chat turns (the decisive v3
    /// shape), not folded rules.
    func testFewShotsAreRealChatTurns() {
        let b = CorrectionPromptBuilder()
        XCTAssertEqual(b.fewShots.count, 4)
        XCTAssertEqual(b.fewShots.first?.assistant, "他明天来我家吃饭")
        XCTAssertEqual(b.fewShots.first?.user.hasSuffix("\n输出:"), true)
        // Covers the 做/作 (加→家), 的/得, 在/再, transparent-passthrough cases.
        XCTAssertEqual(b.fewShots.map(\.assistant),
                       ["他明天来我家吃饭", "这件事情做得很好", "那我们改天再聊", "今天天气很好"])
    }

    func testFoundationModelsInstructionsFoldInFewShots() {
        let b = CorrectionPromptBuilder()
        let fm = b.foundationModelsInstructions()
        XCTAssertTrue(fm.hasPrefix(CorrectionPromptBuilder.defaultSystemInstructions))
        XCTAssertTrue(fm.contains("他明天来我家吃饭"))
    }

    func testCustomBuilderOverridesDefaults() {
        let b = CorrectionPromptBuilder(systemInstructions: "SYS",
                                        fewShots: [.init(user: "u\n输出:", assistant: "a")])
        XCTAssertEqual(b.systemInstructions, "SYS")
        XCTAssertEqual(b.foundationModelsInstructions(), "SYS\n\n以下是几个修正示例:\nu\n输出:a")
    }
}

final class CorrectionPostProcessorTests: XCTestCase {
    func testTakesFirstLineOnly() {
        XCTAssertEqual(CorrectionPostProcessor.normalize("今天天气\n解释:模型多说了", engineBest: "今天天气"),
                       "今天天气")
    }

    func testStripsModelAddedTrailingPunctuation() {
        XCTAssertEqual(CorrectionPostProcessor.normalize("今天天气。", engineBest: "今天天气"), "今天天气")
        XCTAssertEqual(CorrectionPostProcessor.normalize("今天天气!", engineBest: "今天天气"), "今天天气")
        XCTAssertEqual(CorrectionPostProcessor.normalize("今天天气？", engineBest: "今天天气"), "今天天气")
    }

    func testKeepsTrailingPunctuationEngineBestAlreadyHad() {
        XCTAssertEqual(CorrectionPostProcessor.normalize("你好。", engineBest: "你好。"), "你好。")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(CorrectionPostProcessor.normalize("  你好  ", engineBest: "你好"), "你好")
    }
}
