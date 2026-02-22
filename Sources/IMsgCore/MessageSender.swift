import Foundation
import Darwin

public enum MessageService: String, Sendable, CaseIterable {
  case auto
  case imessage
  case sms
}

public struct MessageSendOptions: Sendable {
  public var recipient: String
  public var text: String
  public var attachmentPath: String
  public var service: MessageService
  public var region: String
  public var chatIdentifier: String
  public var chatGUID: String

  public init(
    recipient: String,
    text: String = "",
    attachmentPath: String = "",
    service: MessageService = .auto,
    region: String = "US",
    chatIdentifier: String = "",
    chatGUID: String = ""
  ) {
    self.recipient = recipient
    self.text = text
    self.attachmentPath = attachmentPath
    self.service = service
    self.region = region
    self.chatIdentifier = chatIdentifier
    self.chatGUID = chatGUID
  }
}

public struct MessageSendPlan: Sendable {
  public let recipient: String
  public let text: String
  public let service: String
  public let attachmentPath: String
  public let chatTarget: String
  public let useChat: Bool

  public var useAttachment: Bool {
    attachmentPath.isEmpty == false
  }
}

public struct MessageSender {
  private let normalizer: PhoneNumberNormalizer
  private let attachmentsSubdirectoryProvider: () -> URL

  public init() {
    self.normalizer = PhoneNumberNormalizer()
    self.attachmentsSubdirectoryProvider = MessageSender.defaultAttachmentsSubdirectory
  }

  public init(attachmentsSubdirectoryProvider: @escaping () -> URL) {
    self.normalizer = PhoneNumberNormalizer()
    self.attachmentsSubdirectoryProvider = attachmentsSubdirectoryProvider
  }

  public func prepare(_ options: MessageSendOptions) throws -> MessageSendPlan {
    var resolved = options
    let chatTarget = resolveChatTarget(&resolved)
    let useChat = !chatTarget.isEmpty
    if useChat == false {
      if resolved.region.isEmpty { resolved.region = "US" }
      resolved.recipient = normalizer.normalize(resolved.recipient, region: resolved.region)
      if resolved.service == .auto { resolved.service = .imessage }
    }

    if resolved.attachmentPath.isEmpty == false {
      resolved.attachmentPath = try stageAttachment(at: resolved.attachmentPath)
    }

    return MessageSendPlan(
      recipient: resolved.recipient,
      text: resolved.text,
      service: resolved.service.rawValue,
      attachmentPath: resolved.attachmentPath,
      chatTarget: chatTarget,
      useChat: useChat
    )
  }

  private func stageAttachment(at path: String) throws -> String {
    let expandedPath = Self.expandTildeToRealHome(path)
    let sourceURL = URL(fileURLWithPath: expandedPath)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      throw IMsgError.appleScriptFailure("Attachment not found at \(sourceURL.path)")
    }

    let subdirectory = attachmentsSubdirectoryProvider()
    try fileManager.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    let attachmentDir = subdirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try fileManager.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
    let destination = attachmentDir.appendingPathComponent(
      sourceURL.lastPathComponent,
      isDirectory: false
    )
    try fileManager.copyItem(at: sourceURL, to: destination)
    return destination.path
  }

  private static func defaultAttachmentsSubdirectory() -> URL {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    let messagesRoot = home.appendingPathComponent(
      "Library/Messages/Attachments",
      isDirectory: true
    )
    return messagesRoot.appendingPathComponent("imsg", isDirectory: true)
  }

  private func resolveChatTarget(_ options: inout MessageSendOptions) -> String {
    let guid = options.chatGUID.trimmingCharacters(in: .whitespacesAndNewlines)
    let identifier = options.chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !identifier.isEmpty && looksLikeHandle(identifier) {
      if options.recipient.isEmpty {
        options.recipient = identifier
      }
      return ""
    }
    if !guid.isEmpty {
      return guid
    }
    if identifier.isEmpty {
      return ""
    }
    return identifier
  }

  private func looksLikeHandle(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("imessage:") || lower.hasPrefix("sms:") || lower.hasPrefix("auto:") {
      return true
    }
    if trimmed.contains("@") { return true }
    let allowed = CharacterSet(charactersIn: "+0123456789 ()-")
    return trimmed.rangeOfCharacter(from: allowed.inverted) == nil
  }

  /// Expands `~/...` paths using the real home directory instead of
  /// the sandbox container that `expandingTildeInPath` uses.
  private static func expandTildeToRealHome(_ path: String) -> String {
    guard path.hasPrefix("~/") else { return path }
    if let pw = getpwuid(getuid()) {
      return String(cString: pw.pointee.pw_dir) + String(path.dropFirst(1))
    }
    return (path as NSString).expandingTildeInPath
  }
}
