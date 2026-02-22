import Foundation

/// Builds AppleScript for sending tapback reactions in Messages.app.
///
/// For **standard reactions** (love, like, dislike, laugh, emphasis, question),
/// the script opens the chat via `open location`, then uses `Cmd+T` followed by
/// the reaction's number key (1–6).
///
/// For **custom emoji reactions**, the script opens the tapback popup, clicks
/// the "Add custom emoji reaction" button via accessibility, then finds and
/// clicks the target emoji button in the full emoji picker.
///
/// Both paths require Accessibility permission for the executing process.
public struct ReactionScriptBuilder: Sendable {

    /// Derives the `open location` URL for navigating to a chat.
    public static func chatURL(chatGUID: String, chatIdentifier: String) -> String {
        let scheme: String
        let lowered = chatGUID.lowercased()
        if lowered.hasPrefix("sms;") {
            scheme = "sms"
        } else {
            scheme = "imessage"
        }

        let identifier: String
        if let separatorRange = chatGUID.range(of: ";-;") {
            identifier = String(chatGUID[separatorRange.upperBound...])
        } else {
            identifier = chatIdentifier
        }

        return "\(scheme)://\(identifier)"
    }

    /// Returns the AppleScript source and its arguments list for sending a reaction.
    public static func build(
        reactionType: ReactionType,
        chatGUID: String,
        chatIdentifier: String
    ) -> (script: String, arguments: [String]) {
        let url = chatURL(chatGUID: chatGUID, chatIdentifier: chatIdentifier)

        switch reactionType {
        case .custom(let emoji):
            let script = customEmojiArgvScript()
            return (script, [url, emoji])

        case .love, .like, .dislike, .laugh, .emphasis, .question:
            let keyNumber = reactionKeyNumber(reactionType)
            let script = standardArgvScript()
            return (script, [url, "\(keyNumber)"])
        }
    }

    /// Returns a self-contained AppleScript (no `on run argv`) with values
    /// baked in. Use this with `NSAppleScript` which doesn't support arguments.
    public static func buildInline(
        reactionType: ReactionType,
        chatGUID: String,
        chatIdentifier: String
    ) -> String {
        let url = chatURL(chatGUID: chatGUID, chatIdentifier: chatIdentifier)
        let escapedURL = appleScriptLiteral(url)

        switch reactionType {
        case .custom(let emoji):
            let escapedEmoji = appleScriptLiteral(emoji)
            return customEmojiInlineScript(escapedURL: escapedURL, escapedEmoji: escapedEmoji)

        case .love, .like, .dislike, .laugh, .emphasis, .question:
            let keyNumber = reactionKeyNumber(reactionType)
            return standardInlineScript(escapedURL: escapedURL, keyNumber: keyNumber)
        }
    }

    /// Preferred chat lookup string — display name, then identifier, then GUID.
    public static func preferredChatLookup(chatInfo: ChatInfo) -> String {
        let preferred = chatInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { return preferred }
        let identifier = chatInfo.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identifier.isEmpty { return identifier }
        return chatInfo.guid
    }

    // MARK: - Standard Reaction Scripts

    private static func standardArgvScript() -> String {
        return """
        on run argv
          set chatURL to item 1 of argv
          set reactionKey to item 2 of argv

          open location chatURL
          delay 1.5

          tell application "System Events"
            tell process "Messages"
              set frontmost to true
              try
                perform action "AXRaise" of window 1
              end try
              delay 0.3
              keystroke "t" using command down
              delay 0.5
              keystroke reactionKey
            end tell
          end tell
        end run
        """
    }

    private static func standardInlineScript(escapedURL: String, keyNumber: Int) -> String {
        return """
        open location \(escapedURL)
        delay 1.5

        tell application "System Events"
          tell process "Messages"
            set frontmost to true
            try
              perform action "AXRaise" of window 1
            end try
            delay 0.3
            keystroke "t" using command down
            delay 0.5
            keystroke "\(keyNumber)"
          end tell
        end tell
        """
    }

    // MARK: - Custom Emoji Scripts

    private static func customEmojiArgvScript() -> String {
        return """
        on run argv
          set chatURL to item 1 of argv
          set customEmoji to item 2 of argv

          open location chatURL
          delay 1.5

          tell application "System Events"
            tell process "Messages"
              set frontmost to true
              try
                perform action "AXRaise" of window 1
              end try
              delay 0.3

              -- Open tapback popup
              keystroke "t" using command down
              delay 0.8

              -- Click "Add custom emoji reaction" to open the full picker
              set addBtn to missing value
              repeat with elem in entire contents of window 1
                try
                  if role of elem is "AXButton" and description of elem is "Add custom emoji reaction" then
                    set addBtn to elem
                    exit repeat
                  end if
                end try
              end repeat

              if addBtn is missing value then
                key code 53
                error "Could not find emoji picker button"
              end if

              click addBtn
              delay 0.5

              -- Find and click the target emoji button
              set emojiBtn to missing value
              repeat with elem in entire contents of window 1
                try
                  if role of elem is "AXButton" and description of elem is customEmoji then
                    set emojiBtn to elem
                    exit repeat
                  end if
                end try
              end repeat

              if emojiBtn is not missing value then
                click emojiBtn
              else
                key code 53
                error "Emoji " & customEmoji & " not found in picker"
              end if

            end tell
          end tell
        end run
        """
    }

    private static func customEmojiInlineScript(escapedURL: String, escapedEmoji: String) -> String {
        return """
        open location \(escapedURL)
        delay 1.5

        tell application "System Events"
          tell process "Messages"
            set frontmost to true
            try
              perform action "AXRaise" of window 1
            end try
            delay 0.3

            keystroke "t" using command down
            delay 0.8

            set addBtn to missing value
            repeat with elem in entire contents of window 1
              try
                if role of elem is "AXButton" and description of elem is "Add custom emoji reaction" then
                  set addBtn to elem
                  exit repeat
                end if
              end try
            end repeat

            if addBtn is not missing value then
              click addBtn
              delay 0.5

              set emojiBtn to missing value
              repeat with elem in entire contents of window 1
                try
                  if role of elem is "AXButton" and description of elem is \(escapedEmoji) then
                    set emojiBtn to elem
                    exit repeat
                  end if
                end try
              end repeat

              if emojiBtn is not missing value then
                click emojiBtn
              else
                key code 53
              end if
            else
              key code 53
            end if

          end tell
        end tell
        """
    }

    // MARK: - Private Helpers

    private static func reactionKeyNumber(_ reactionType: ReactionType) -> Int {
        switch reactionType {
        case .love: return 1
        case .like: return 2
        case .dislike: return 3
        case .laugh: return 4
        case .emphasis: return 5
        case .question: return 6
        case .custom: return 0
        }
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
