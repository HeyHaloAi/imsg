public enum MessageSendMode: String, Sendable, CaseIterable {
  case applescript
  case imcore
  case auto

  public static func parse(_ value: String) -> MessageSendMode? {
    guard !value.isEmpty else { return nil }
    return MessageSendMode(rawValue: value.lowercased())
  }
}
