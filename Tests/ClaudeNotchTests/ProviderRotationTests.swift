import Testing
@testable import ClaudeNotch

@Suite struct ProviderRotationTests {
    @Test func wrapsAround() {
        let all: [UsageProviderID] = [.claude, .codex, .antigravity]
        #expect(AppModel.provider(after: .claude, in: all) == .codex)
        #expect(AppModel.provider(after: .antigravity, in: all) == .claude)
    }

    /// The provider on screen can stop being available (a CLI uninstalled); the next switch then
    /// starts the list over rather than getting stuck.
    @Test func startsOverWhenTheCurrentOneIsGone() {
        #expect(AppModel.provider(after: .codex, in: [.claude, .antigravity]) == .claude)
    }

    @Test func nothingToRotateWithOneProvider() {
        #expect(AppModel.provider(after: .claude, in: [.claude]) == nil)
    }
}
