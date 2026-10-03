import Foundation

/// opencode-go usage, server meters first with local history as the fallback.
///
/// The local store cannot know the account quota, so it reconstructs windows from spend and
/// hardcodes the plan limits. The web/API path reads the real opencode.ai meters, which is what
/// makes the weekly/monthly windows line up with CodexBar. Either path blocks (Keychain, SQLite),
/// so the fallback runs on a utility queue rather than the cooperative pool.
actor OpencodeGoUsageProvider {
    private static let queue = DispatchQueue(label: "opencode-go-usage", qos: .utility)
    private let api = OpencodeGoAPI()
    /// The last snapshot that actually carried numbers. Returned untouched (its old `fetchedAt`
    /// dims it via the UI's stale check) when a web round trip fails, so a blip never blanks it.
    private var lastGood: ProviderUsageSnapshot?

    func fetch(now: Date = Date()) async -> ProviderUsageSnapshot {
        switch await api.fetch(now: now) {
        case .usage(let snapshot):
            lastGood = snapshot
            return snapshot
        case .failed:
            // A web session existed but the round trip didn't parse or connect: keep the last good
            // numbers rather than replacing them with account-agnostic local estimates.
            if let lastGood { return lastGood }
            return await resolveLocal(now: now)
        case .unavailable:
            // Nothing web-signed-in to try: local history is the intended fallback, then last good.
            return await resolveLocal(now: now)
        }
    }

    private enum Local: Sendable {
        case snapshot(ProviderUsageSnapshot)
        case unavailable(String)
    }

    private func resolveLocal(now: Date) async -> ProviderUsageSnapshot {
        switch await local(now: now) {
        case .snapshot(let snapshot):
            lastGood = snapshot
            return snapshot
        case .unavailable(let message):
            return lastGood ?? .unavailable(.opencodeGo, message: message)
        }
    }

    private func local(now: Date) async -> Local {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: .snapshot(try OpencodeGoLocalUsage.fetch(now: now)))
                } catch {
                    continuation.resume(returning: .unavailable(
                        (error as? LocalizedError)?.errorDescription ?? "opencode-go usage unavailable"))
                }
            }
        }
    }
}
