import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct UsageStoreTests {
    func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
    }

    @Test func dedupesAndAggregates() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("dedup"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let now = f.date(from: "2026-07-03T10:30:00Z")!
        let snap = store.snapshot(now: now)
        #expect(snap.tokensToday == 1_500_000)
        // 1M input on Opus 4.8 @ $5/M + 500K on Haiku 4.5 @ $1/M. Was $15.40 when the table
        // priced all Opus at the retired $15/M and all Haiku at Haiku 3.5's $0.80/M.
        #expect(abs(snap.costToday - 5.50) < 0.0001)
        #expect(snap.topModel == "claude-opus-4-8")
        #expect(snap.blockRemaining != nil)
        #expect(!snap.isEmpty)
    }

    /// Regression: the fallback estimate used to divide the active block by a maximum that
    /// included the active block itself, so a single block reported a fabricated 100% — which the
    /// UI reads as "out of budget" (red ring, Clawd frozen) when nothing was actually measured.
    @Test func singleBlockHasNoUsageEstimate() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("dedup"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let snap = store.snapshot(now: f.date(from: "2026-07-03T10:30:00Z")!)
        #expect(snap.blockUsageEstimate == nil)
    }

    /// With a completed block to compare against, the estimate is a real ratio.
    @Test func estimateComparesAgainstCompletedBlock() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("two-blocks"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let snap = store.snapshot(now: f.date(from: "2026-07-03T10:30:00Z")!)
        // active 500K against a completed 1M block
        #expect(snap.blockUsageEstimate == 0.5)
    }

    /// No active block means no current-block ratio to report.
    @Test func expiredBlockHasNoUsageEstimate() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("two-blocks"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let snap = store.snapshot(now: f.date(from: "2026-07-04T09:00:00Z")!)
        #expect(snap.blockUsageEstimate == nil)
    }

    @Test func emptyStoreIsEmptySnapshot() {
        let snap = UsageStore().snapshot(now: Date())
        #expect(snap.isEmpty)
        #expect(snap.tokensToday == 0)
        #expect(snap.blockRemaining == nil)
    }
}
