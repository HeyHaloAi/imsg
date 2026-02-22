import Cocoa
import ApplicationServices

/// Sends custom emoji reactions via the macOS Accessibility API.
///
/// Standard reactions (love, like, etc.) use AppleScript keystrokes
/// (Cmd+T + number key). Custom emoji reactions require navigating the
/// full emoji picker which AppleScript cannot reliably do. This type
/// uses AXUIElement to:
/// 1. Focus the last message in the transcript
/// 2. Open the tapback popup (Cmd+T via CGEvent)
/// 3. Click "Add custom emoji reaction" to open the full picker
/// 4. Find the target emoji button in the picker grid
/// 5. Click it to apply the reaction
///
/// Requires Accessibility permission for the calling process.
public struct AccessibilityReactor: Sendable {

    public enum ReactError: Error, LocalizedError, Sendable {
        case messagesNotRunning
        case noWindow
        case transcriptNotFound
        case noMessageFound
        case tapbackDidNotOpen
        case emojiPickerButtonNotFound
        case emojiPickerDidNotOpen
        case emojiNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .messagesNotRunning: "Messages.app is not running"
            case .noWindow: "Messages has no open window"
            case .transcriptNotFound: "Could not find message transcript"
            case .noMessageFound: "No message found to react to"
            case .tapbackDidNotOpen: "Tapback popup did not open"
            case .emojiPickerButtonNotFound: "Could not find 'Add custom emoji reaction' button"
            case .emojiPickerDidNotOpen: "Emoji picker did not open"
            case .emojiNotFound(let e): "Emoji \(e) not found in picker"
            }
        }
    }

    /// Sends a custom emoji reaction to the last message in a chat.
    ///
    /// - Parameters:
    ///   - chatURL: The `imessage://` or `sms://` URL for the target chat.
    ///   - emoji: The emoji character to react with.
    /// - Throws: ``ReactError`` on failure.
    public static func react(chatURL: String, emoji: String) throws {
        // Step 1: Navigate to the chat
        guard let url = URL(string: chatURL) else {
            throw ReactError.messagesNotRunning
        }
        NSWorkspace.shared.open(url)
        Thread.sleep(forTimeInterval: 2.0)

        // Step 2: Get Messages process
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.MobileSMS"
        )
        guard let app = apps.first else { throw ReactError.messagesNotRunning }
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = firstWindow(of: appRef) else { throw ReactError.noWindow }

        // Step 3: Focus the last message
        guard let transcript = findByIdentifier(win, "TranscriptCollectionView") else {
            throw ReactError.transcriptNotFound
        }
        let messages = children(of: transcript)
        guard let lastMsg = findLastReactableMessage(in: messages) else {
            throw ReactError.noMessageFound
        }

        if let textArea = findCKBalloonTextView(in: lastMsg) {
            _ = axSetFocused(textArea)
        }
        _ = axPress(lastMsg)
        Thread.sleep(forTimeInterval: 0.3)

        // Step 4: Open tapback popup (Cmd+T via CGEvent)
        sendKey(17, flags: .maskCommand)  // 't'
        Thread.sleep(forTimeInterval: 1.5)

        // Verify tapback opened
        guard findByDescription(win, "Add custom emoji reaction") != nil else {
            throw ReactError.tapbackDidNotOpen
        }

        // Step 5: Click "Add custom emoji reaction"
        guard let addBtn = findByDescription(win, "Add custom emoji reaction") else {
            throw ReactError.emojiPickerButtonNotFound
        }
        _ = axPress(addBtn)
        Thread.sleep(forTimeInterval: 1.5)

        // Step 6: Find the emoji picker popover
        guard let popover = findByRole(win, "AXPopover") else {
            sendKey(53)  // Escape
            throw ReactError.emojiPickerDidNotOpen
        }

        // Step 7: Find and click the target emoji button
        guard let emojiBtn = findByDescription(popover, emoji, maxDepth: 10) else {
            sendKey(53)  // Escape
            throw ReactError.emojiNotFound(emoji)
        }
        _ = axPress(emojiBtn)
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - AX Helpers

    private static func attr(_ elem: AXUIElement, _ key: String) -> CFTypeRef? {
        var val: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, key as CFString, &val)
        return val
    }

    private static func str(_ elem: AXUIElement, _ key: String) -> String {
        guard let v = attr(elem, key) else { return "" }
        return v as? String ?? ""
    }

    private static func children(of elem: AXUIElement) -> [AXUIElement] {
        guard let v = attr(elem, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return v
    }

    private static func axPress(_ elem: AXUIElement) -> AXError {
        AXUIElementPerformAction(elem, kAXPressAction as CFString)
    }

    private static func axSetFocused(_ elem: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(
            elem, kAXFocusedAttribute as CFString, true as CFBoolean
        )
    }

    private static func firstWindow(of app: AXUIElement) -> AXUIElement? {
        guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] else {
            return nil
        }
        return windows.first
    }

    private static func findByIdentifier(
        _ root: AXUIElement, _ identifier: String,
        maxDepth: Int = 6, depth: Int = 0
    ) -> AXUIElement? {
        if str(root, "AXIdentifier") == identifier { return root }
        guard depth < maxDepth else { return nil }
        for child in children(of: root) {
            if let f = findByIdentifier(child, identifier, maxDepth: maxDepth, depth: depth + 1) {
                return f
            }
        }
        return nil
    }

    private static func findByDescription(
        _ root: AXUIElement, _ description: String,
        maxDepth: Int = 6, depth: Int = 0
    ) -> AXUIElement? {
        if str(root, kAXRoleAttribute) == "AXButton" &&
            str(root, kAXDescriptionAttribute) == description {
            return root
        }
        guard depth < maxDepth else { return nil }
        for child in children(of: root) {
            if let f = findByDescription(child, description, maxDepth: maxDepth, depth: depth + 1) {
                return f
            }
        }
        return nil
    }

    private static func findByRole(
        _ root: AXUIElement, _ role: String,
        maxDepth: Int = 4, depth: Int = 0
    ) -> AXUIElement? {
        if str(root, kAXRoleAttribute) == role { return root }
        guard depth < maxDepth else { return nil }
        for child in children(of: root) {
            if let f = findByRole(child, role, maxDepth: maxDepth, depth: depth + 1) {
                return f
            }
        }
        return nil
    }

    private static func findCKBalloonTextView(
        in root: AXUIElement, depth: Int = 0
    ) -> AXUIElement? {
        if str(root, kAXRoleAttribute) == "AXTextArea" &&
            str(root, "AXIdentifier") == "CKBalloonTextView" {
            return root
        }
        guard depth < 4 else { return nil }
        for child in children(of: root) {
            if let f = findCKBalloonTextView(in: child, depth: depth + 1) { return f }
        }
        return nil
    }

    private static func findLastReactableMessage(
        in messages: [AXUIElement]
    ) -> AXUIElement? {
        for msg in messages.reversed() {
            let desc = str(msg, kAXDescriptionAttribute)
            if !desc.isEmpty &&
                !desc.contains("Read") &&
                !desc.contains("notifications silenced") {
                return msg
            }
        }
        return nil
    }

    private static func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}
