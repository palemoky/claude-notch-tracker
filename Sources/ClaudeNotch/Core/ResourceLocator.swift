import Foundation

/// Finds bundled resources in both layouts the app runs from: the packaged .app (resources copied
/// into Contents/Resources/ClaudeNotch_ClaudeNotch.bundle by make-app.sh) and `swift run`, where
/// SwiftPM's `Bundle.module` resolves them.
enum ResourceLocator {
    static var bundle: Bundle {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent("ClaudeNotch_ClaudeNotch.bundle")) {
            return packaged
        }
        return Bundle.module
    }

    static func urls(prefix: String, ext: String) -> [URL] {
        (bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
}
