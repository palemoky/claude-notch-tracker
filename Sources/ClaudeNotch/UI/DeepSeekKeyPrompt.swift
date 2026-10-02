import AppKit

/// The right-click menu's "DeepSeek API Key…": a secure field that saves the key to the login
/// Keychain, or removes the saved one. There is no settings window to put this in, and a key is
/// a one-off, so a modal alert is enough.
@MainActor
enum DeepSeekKeyPrompt {
    static func run(onChange: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = "DeepSeek API Key"
        let hasStored = DeepSeekCredentials.isConfigured && DeepSeekCredentials.environmentKey == nil
        var info = "Create a key at platform.deepseek.com/api_keys. It is stored in your Keychain "
            + "and only ever sent to api.deepseek.com, to read your balance."
        if DeepSeekCredentials.environmentKey != nil {
            info += "\n\nDEEPSEEK_API_KEY is set in this app's environment and takes precedence."
        }
        alert.informativeText = info

        let field = EditableSecureField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = hasStored ? "Saved — paste a new key to replace it" : "sk-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if hasStored { alert.addButton(withTitle: "Remove Key") }
        alert.window.initialFirstResponder = field

        // The island is a non-activating panel; without this the alert opens behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard DeepSeekCredentials.save(field.stringValue) else { return }
            onChange()
        case .alertThirdButtonReturn:
            DeepSeekCredentials.remove()
            onChange()
        default:
            return
        }
    }
}

/// ⌘V reaches a text field through the Edit menu's key equivalents, and an accessory app has no
/// menu bar to carry them — so in a plain field here, pasting a key silently did nothing. The
/// field answers the editing shortcuts itself instead.
private final class EditableSecureField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector? = switch key {
        case "v": #selector(NSText.paste(_:))
        case "a": #selector(NSText.selectAll(_:))
        case "x": #selector(NSText.cut(_:))
        case "c": #selector(NSText.copy(_:))
        case "z": Selector(("undo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
