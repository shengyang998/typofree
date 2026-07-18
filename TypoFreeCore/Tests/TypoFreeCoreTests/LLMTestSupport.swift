import XCTest
import Foundation
@testable import TypoFreeCore

// Shared fakes + helpers for the M4 LLM-correction tests (DESIGN.md §2.4/§9).
// Everything here is zero-Metal, zero-network: coordinator/gate/state-machine
// behavior is exercised with fake `LLMCorrectionProvider`s only.

/// Records whether `correct()` was ever entered on the main thread — the
/// enforcement of the provider-isolation hard contract (§3, concurrency risk #2).
actor MainThreadWitness {
    private(set) var records: [Bool] = []
    private(set) var everRanOnMain = false
    func record(onMain: Bool) {
        records.append(onMain)
        if onMain { everRanOnMain = true }
    }
}

/// A fully scriptable fake provider. `handler` decides each call's outcome; the
/// provider is an `actor`, so `correct()` runs off the main thread by
/// construction (which the witness verifies).
actor ScriptedProvider: LLMCorrectionProvider {
    nonisolated let id: LLMBackendID
    private let handler: @Sendable (CorrectionRequest) async -> CorrectionResult?
    private let witness: MainThreadWitness?
    private(set) var callCount = 0
    private(set) var seenRequestIDs: [UInt64] = []
    private(set) var releaseCount = 0
    private(set) var prewarmCount = 0

    init(id: LLMBackendID = .mlx, witness: MainThreadWitness? = nil,
         handler: @escaping @Sendable (CorrectionRequest) async -> CorrectionResult?) {
        self.id = id
        self.witness = witness
        self.handler = handler
    }

    func availability() async -> LLMProviderAvailability { .ready }
    func prewarm() async { prewarmCount += 1 }

    func correct(_ request: CorrectionRequest) async -> CorrectionResult? {
        // `pthread_main_np()` is the async-safe way to ask "am I on the main
        // thread" (`Thread.isMainThread` is banned in async contexts). The
        // MainActor runs on the main thread, so this detects a contract breach.
        let onMain = (pthread_main_np() != 0)   // captured at entry, before any await
        callCount += 1
        seenRequestIDs.append(request.id)
        if let witness { await witness.record(onMain: onMain) }
        return await handler(request)
    }

    func releaseResources() async { releaseCount += 1 }
}

/// Collects coordinator events for assertions, with a polling `waitForCount`
/// (the coordinator uses a real `ContinuousClock` in these tests, so we can't
/// deterministically step time — we bound waits instead).
actor EventCollector {
    private(set) var events: [CorrectionEvent] = []

    func append(_ e: CorrectionEvent) { events.append(e) }
    func count() -> Int { events.count }
    func all() -> [CorrectionEvent] { events }

    func waitForCount(_ n: Int, timeout: Duration = .seconds(2)) async -> [CorrectionEvent] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while events.count < n && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events
    }
}

/// Pumps a coordinator's single-consumer event stream into a collector.
func pumpEvents(_ stream: AsyncStream<CorrectionEvent>, into collector: EventCollector) -> Task<Void, Never> {
    Task { for await e in stream { await collector.append(e) } }
}

enum LLMTestFactory {
    /// A validator backed by the REAL bundled `readings.bin` + flypy decoder —
    /// so heteronym coverage (得/行/银) is exercised end to end.
    static func realValidator() throws -> CorrectionValidator {
        let index = try PinyinReadingIndex.loadBundled()
        let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)
        return CorrectionValidator(index: index, decoder: decoder)
    }

    static let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)

    /// The concatenated 小鹤 codes for a list of toneless syllables (test anchor).
    static func codes(_ syllables: [String]) -> String {
        decoder.encode(tonelessSyllables: syllables) ?? ""
    }
}
