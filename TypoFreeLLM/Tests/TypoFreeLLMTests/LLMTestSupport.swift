import Foundation
import XCTest
@testable import TypoFreeLLM
import TypoFreeCore

// Zero-Metal, zero-network fakes for the TypoFreeLLM tests (DESIGN.md §2.4/§9).
// The provider state machine / idle-unload / timeout are all exercised through
// `FakeModelRunner`; the real MLX path is only the gated live test.

enum FakeRunnerError: Error { case loadFailed }

/// A `CorrectionModelRunner` with no weights — records load/run/unload counts
/// and can simulate slow loads/runs and load failures.
actor FakeModelRunner: CorrectionModelRunner {
    private(set) var loadCount = 0
    private(set) var runCount = 0
    private(set) var unloadCount = 0
    private var loaded = false

    private let response: String
    private let loadDelay: Duration
    private let runDelay: Duration
    private let loadShouldFail: Bool

    init(response: String = "今天天气", loadDelay: Duration = .zero,
         runDelay: Duration = .zero, loadShouldFail: Bool = false) {
        self.response = response
        self.loadDelay = loadDelay
        self.runDelay = runDelay
        self.loadShouldFail = loadShouldFail
    }

    func load(progress: @Sendable @escaping (Double) -> Void) async throws {
        loadCount += 1
        if loadDelay != .zero { try? await Task.sleep(for: loadDelay) }
        if loadShouldFail { throw FakeRunnerError.loadFailed }
        loaded = true
        progress(1.0)
    }

    func run(request: CorrectionRequest, systemInstructions: String, userPrompt: String) async throws -> String {
        runCount += 1
        if runDelay != .zero { try await Task.sleep(for: runDelay) } // throwing → cancellable by the timeout race
        return response
    }

    func unload() async {
        unloadCount += 1
        loaded = false
    }

    var isLoaded: Bool { loaded }

    func availabilityProbe() async -> LLMProviderAvailability {
        loaded ? .ready : .availableOnDemand
    }
}

enum LLMTestFixtures {
    static func request(_ id: UInt64, engineBest: String = "今天天气") -> CorrectionRequest {
        CorrectionRequest(id: id, precedingContext: "", rawPinyin: "jjwftweqvp",
                          engineBest: engineBest, maxNewTokens: 32)
    }

    static func tempCacheDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "typofree-test-\(UUID().uuidString)")
    }
}
