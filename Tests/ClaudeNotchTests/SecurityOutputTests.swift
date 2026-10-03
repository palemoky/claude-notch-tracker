import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct SecurityOutputTests {
    @Test func plainTextPasswordPassesThrough() {
        let out = Data("{\"claudeAiOauth\":{\"accessToken\":\"t\"}}\n".utf8)
        #expect(ClaudeAPIService.passwordData(fromSecurityOutput: out)
                == Data("{\"claudeAiOauth\":{\"accessToken\":\"t\"}}".utf8))
    }

    /// `security -w` prints hex once the value holds a non-printable byte, e.g. a newline.
    @Test func hexOutputIsDecoded() {
        let json = "{\n  \"a\": 1\n}"
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined() + "\n"
        #expect(ClaudeAPIService.passwordData(fromSecurityOutput: Data(hex.utf8))
                == Data(json.utf8))
    }

    @Test func emptyOutputIsNil() {
        #expect(ClaudeAPIService.passwordData(fromSecurityOutput: Data("\n".utf8)) == nil)
    }
}
