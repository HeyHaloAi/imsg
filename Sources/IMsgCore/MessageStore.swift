import Foundation
import SQLite

public actor MessageStore {
  public static let appleEpochOffset: TimeInterval = 978_307_200

  public static var defaultPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return NSString(string: home).appendingPathComponent("Library/Messages/chat.db")
  }

  public let path: String

  private let connection: Connection
  let hasAttributedBody: Bool
  let hasReactionColumns: Bool
  let hasThreadOriginatorGUIDColumn: Bool
  let hasDestinationCallerID: Bool
  let hasAudioMessageColumn: Bool
  let hasAttachmentUserInfo: Bool

  public init(path: String = MessageStore.defaultPath) throws {
    let normalized = NSString(string: path).expandingTildeInPath
    self.path = normalized
    do {
      let uri = URL(fileURLWithPath: normalized).absoluteString
      let location = Connection.Location.uri(uri, parameters: [.mode(.readOnly)])
      self.connection = try Connection(location, readonly: true)
      self.connection.busyTimeout = 5
      let messageColumns = MessageStore.tableColumns(connection: self.connection, table: "message")
      let attachmentColumns = MessageStore.tableColumns(
        connection: self.connection,
        table: "attachment"
      )
      self.hasAttributedBody = messageColumns.contains("attributedbody")
      self.hasReactionColumns = MessageStore.reactionColumnsPresent(in: messageColumns)
      self.hasThreadOriginatorGUIDColumn = messageColumns.contains("thread_originator_guid")
      self.hasDestinationCallerID = messageColumns.contains("destination_caller_id")
      self.hasAudioMessageColumn = messageColumns.contains("is_audio_message")
      self.hasAttachmentUserInfo = attachmentColumns.contains("user_info")
    } catch {
      throw MessageStore.enhance(error: error, path: normalized)
    }
  }

  init(
    connection: Connection,
    path: String,
    hasAttributedBody: Bool? = nil,
    hasReactionColumns: Bool? = nil,
    hasThreadOriginatorGUIDColumn: Bool? = nil,
    hasDestinationCallerID: Bool? = nil,
    hasAudioMessageColumn: Bool? = nil,
    hasAttachmentUserInfo: Bool? = nil
  ) throws {
    self.path = path
    self.connection = connection
    self.connection.busyTimeout = 5
    let messageColumns = MessageStore.tableColumns(connection: connection, table: "message")
    let attachmentColumns = MessageStore.tableColumns(connection: connection, table: "attachment")
    if let hasAttributedBody {
      self.hasAttributedBody = hasAttributedBody
    } else {
      self.hasAttributedBody = messageColumns.contains("attributedbody")
    }
    if let hasReactionColumns {
      self.hasReactionColumns = hasReactionColumns
    } else {
      self.hasReactionColumns = MessageStore.reactionColumnsPresent(in: messageColumns)
    }
    if let hasThreadOriginatorGUIDColumn {
      self.hasThreadOriginatorGUIDColumn = hasThreadOriginatorGUIDColumn
    } else {
      self.hasThreadOriginatorGUIDColumn = messageColumns.contains("thread_originator_guid")
    }
    if let hasDestinationCallerID {
      self.hasDestinationCallerID = hasDestinationCallerID
    } else {
      self.hasDestinationCallerID = messageColumns.contains("destination_caller_id")
    }
    if let hasAudioMessageColumn {
      self.hasAudioMessageColumn = hasAudioMessageColumn
    } else {
      self.hasAudioMessageColumn = messageColumns.contains("is_audio_message")
    }
    if let hasAttachmentUserInfo {
      self.hasAttachmentUserInfo = hasAttachmentUserInfo
    } else {
      self.hasAttachmentUserInfo = attachmentColumns.contains("user_info")
    }
  }

  public func listChats(limit: Int) async throws -> [Chat] {
    let sql = """
      SELECT c.ROWID, CASE WHEN IFNULL(c.display_name, '') = '' THEN c.chat_identifier ELSE c.display_name END AS name, c.chat_identifier, c.service_name,
             MAX(m.date) AS last_date
      FROM chat c
      JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
      JOIN message m ON m.ROWID = cmj.message_id
      GROUP BY c.ROWID
      ORDER BY last_date DESC
      LIMIT ?
      """
    return try withConnection { db in
      var chats: [Chat] = []
      for row in try db.prepare(sql, limit) {
        let id = int64Value(row[0]) ?? 0
        let name = stringValue(row[1])
        let identifier = stringValue(row[2])
        let service = stringValue(row[3])
        let lastDate = appleDate(from: int64Value(row[4]))
        chats.append(
          Chat(
            id: id, identifier: identifier, name: name, service: service, lastMessageAt: lastDate))
      }
      return chats
    }
  }

  public func chatInfo(chatID: Int64) async throws -> ChatInfo? {
    let sql = """
      SELECT c.ROWID, IFNULL(c.chat_identifier, '') AS identifier, IFNULL(c.guid, '') AS guid,
             CASE WHEN IFNULL(c.display_name, '') = '' THEN c.chat_identifier ELSE c.display_name END AS name, IFNULL(c.service_name, '') AS service
      FROM chat c
      WHERE c.ROWID = ?
      LIMIT 1
      """
    return try withConnection { db in
      for row in try db.prepare(sql, chatID) {
        let id = int64Value(row[0]) ?? 0
        let identifier = stringValue(row[1])
        let guid = stringValue(row[2])
        let name = stringValue(row[3])
        let service = stringValue(row[4])
        return ChatInfo(
          id: id,
          identifier: identifier,
          guid: guid,
          name: name,
          service: service
        )
      }
      return nil
    }
  }

  public func chatInfo(chatIdentifier: String?, chatGUID: String?) async throws -> ChatInfo? {
    let identifier = chatIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let guid = chatGUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard identifier.isEmpty == false || guid.isEmpty == false else { return nil }

    var clauses: [String] = []
    var bindings: [Binding?] = []
    if identifier.isEmpty == false {
      clauses.append("c.chat_identifier = ?")
      bindings.append(identifier)
    }
    if guid.isEmpty == false {
      clauses.append("c.guid = ?")
      bindings.append(guid)
    }

    let sql = """
      SELECT c.ROWID, IFNULL(c.chat_identifier, '') AS identifier, IFNULL(c.guid, '') AS guid,
             CASE WHEN IFNULL(c.display_name, '') = '' THEN c.chat_identifier ELSE c.display_name END AS name, IFNULL(c.service_name, '') AS service
      FROM chat c
      WHERE (
        \(clauses.joined(separator: " OR "))
      )
      LIMIT 1
      """
    return try withConnection { db in
      for row in try db.prepare(sql, bindings) {
        let id = int64Value(row[0]) ?? 0
        let resolvedIdentifier = stringValue(row[1])
        let resolvedGuid = stringValue(row[2])
        let name = stringValue(row[3])
        let service = stringValue(row[4])
        return ChatInfo(
          id: id,
          identifier: resolvedIdentifier,
          guid: resolvedGuid,
          name: name,
          service: service
        )
      }
      return nil
    }
  }

  public func participants(chatID: Int64) async throws -> [String] {
    let sql = """
      SELECT h.id
      FROM chat_handle_join chj
      JOIN handle h ON h.ROWID = chj.handle_id
      WHERE chj.chat_id = ?
      ORDER BY h.id ASC
      """
    return try withConnection { db in
      var results: [String] = []
      var seen = Set<String>()
      for row in try db.prepare(sql, chatID) {
        let handle = stringValue(row[0])
        if handle.isEmpty { continue }
        if seen.insert(handle).inserted {
          results.append(handle)
        }
      }
      return results
    }
  }

  func withConnection<T>(_ block: (Connection) throws -> T) throws -> T {
    try block(connection)
  }

  /// Checks whether a handle has an **active** iMessage chat.
  ///
  /// A handle is considered iMessage-capable when it has a chat with
  /// `service_name = 'iMessage'` AND at least one successfully
  /// delivered message (`is_delivered = 1` or `is_sent = 1` with
  /// `error = 0`) within the last 365 days.  Old or failed-only chats
  /// are treated as stale / deregistered.
  public func hasImessageChat(handle: String) throws -> Bool {
    let normalized = handle
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "(", with: "")
      .replacingOccurrences(of: ")", with: "")
    // 365 days ago in Apple's nanosecond epoch
    let cutoff = (Date().timeIntervalSinceReferenceDate - 365 * 86400) * 1_000_000_000
    let sql = """
      SELECT COUNT(*) FROM chat c
      JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE c.chat_identifier = ?
        AND c.service_name = 'iMessage'
        AND m.date > ?
        AND m.error = 0
        AND (m.is_delivered = 1 OR m.is_sent = 1)
      LIMIT 1
      """
    return try withConnection { db in
      for row in try db.prepare(sql, normalized, Int64(cutoff)) {
        return (int64Value(row[0]) ?? 0) > 0
      }
      return false
    }
  }

  /// Finds the first iMessage-capable handle from a list of candidates.
  ///
  /// Returns the handle that has an active iMessage chat, or `nil` if
  /// none of the candidates are iMessage-capable.
  public func firstImessageHandle(from candidates: [String]) throws -> String? {
    guard candidates.isEmpty == false else { return nil }
    let placeholders = candidates.map { _ in "?" }.joined(separator: ", ")
    let sql = """
      SELECT chat_identifier FROM chat
      WHERE chat_identifier IN (\(placeholders)) AND service_name = 'iMessage'
      LIMIT 1
      """
    return try withConnection { db in
      let bindings: [Binding?] = candidates.map { $0 as Binding? }
      for row in try db.prepare(sql, bindings) {
        let result = stringValue(row[0])
        return result.isEmpty ? nil : result
      }
      return nil
    }
  }
}

extension MessageStore {
  public func attachments(for messageID: Int64) async throws -> [AttachmentMeta] {
    let sql = """
      SELECT a.filename, a.transfer_name, a.uti, a.mime_type, a.total_bytes, a.is_sticker
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ?
      """
    return try withConnection { db in
      var metas: [AttachmentMeta] = []
      for row in try db.prepare(sql, messageID) {
        let filename = stringValue(row[0])
        let transferName = stringValue(row[1])
        let uti = stringValue(row[2])
        let mimeType = stringValue(row[3])
        let totalBytes = int64Value(row[4]) ?? 0
        let isSticker = boolValue(row[5])
        let resolved = AttachmentResolver.resolve(filename)
        metas.append(
          AttachmentMeta(
            filename: filename,
            transferName: transferName,
            uti: uti,
            mimeType: mimeType,
            totalBytes: totalBytes,
            isSticker: isSticker,
            originalPath: resolved.resolved,
            missing: resolved.missing
          ))
      }
      return metas
    }
  }

  func audioTranscription(for messageID: Int64) throws -> String? {
    guard hasAttachmentUserInfo else { return nil }
    let sql = """
      SELECT a.user_info
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ?
      LIMIT 1
      """
    return try withConnection { db in
      for row in try db.prepare(sql, messageID) {
        let info = dataValue(row[0])
        guard !info.isEmpty else { continue }
        if let transcription = parseAudioTranscription(from: info) {
          return transcription
        }
      }
      return nil
    }
  }

  private func parseAudioTranscription(from data: Data) -> String? {
    do {
      let plist = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
      guard
        let dict = plist as? [String: Any],
        let transcription = dict["audio-transcription"] as? String,
        !transcription.isEmpty
      else {
        return nil
      }
      return transcription
    } catch {
      return nil
    }
  }

  public func maxRowID() async throws -> Int64 {
    return try withConnection { db in
      let value = try db.scalar("SELECT MAX(ROWID) FROM message")
      return int64Value(value) ?? 0
    }
  }

  public func reactions(for messageID: Int64) async throws -> [Reaction] {
    guard hasReactionColumns else { return [] }
    // Reactions are stored as messages with associated_message_type in range 2000-2006
    // 2000-2005 are standard tapbacks, 2006 is custom emoji reactions
    // They reference the original message via associated_message_guid which has format "p:X/GUID"
    // where X is the part index (0 for single-part messages) and GUID matches the original message's guid
    let bodyColumn = hasAttributedBody ? "r.attributedBody" : "NULL"
    let sql = """
      SELECT r.ROWID, r.associated_message_type, h.id, r.is_from_me, r.date, IFNULL(r.text, '') as text,
             \(bodyColumn) AS body
      FROM message m
      JOIN message r ON r.associated_message_guid = m.guid
        OR r.associated_message_guid LIKE '%/' || m.guid
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE m.ROWID = ?
        AND m.guid IS NOT NULL
        AND m.guid != ''
        AND r.associated_message_type >= 2000
        AND r.associated_message_type <= 3006
      ORDER BY r.date ASC
      """
    return try withConnection { db in
      var reactions: [Reaction] = []
      var reactionIndex: [ReactionKey: Int] = [:]
      for row in try db.prepare(sql, messageID) {
        let rowID = int64Value(row[0]) ?? 0
        let typeValue = intValue(row[1]) ?? 0
        let sender = stringValue(row[2])
        let isFromMe = boolValue(row[3])
        let date = appleDate(from: int64Value(row[4]))
        let text = stringValue(row[5])
        let body = dataValue(row[6])
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text

        if ReactionType.isReactionRemove(typeValue) {
          let customEmoji = typeValue == 3006 ? extractCustomEmoji(from: resolvedText) : nil
          let reactionType = ReactionType.fromRemoval(typeValue, customEmoji: customEmoji)
          if let reactionType {
            let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
            if let index = reactionIndex.removeValue(forKey: key) {
              reactions.remove(at: index)
              reactionIndex = ReactionKey.reindex(reactions: reactions)
            }
            continue
          }
          if typeValue == 3006 {
            if let index = reactions.firstIndex(where: {
              $0.sender == sender && $0.isFromMe == isFromMe && $0.reactionType.isCustom
            }) {
              reactions.remove(at: index)
              reactionIndex = ReactionKey.reindex(reactions: reactions)
            }
          }
          continue
        }

        let customEmoji: String? = typeValue == 2006 ? extractCustomEmoji(from: resolvedText) : nil
        guard let reactionType = ReactionType(rawValue: typeValue, customEmoji: customEmoji) else {
          continue
        }

        let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
        if let index = reactionIndex[key] {
          reactions[index] = Reaction(
            rowID: rowID,
            reactionType: reactionType,
            sender: sender,
            isFromMe: isFromMe,
            date: date,
            associatedMessageID: messageID
          )
        } else {
          reactionIndex[key] = reactions.count
          reactions.append(
            Reaction(
              rowID: rowID,
              reactionType: reactionType,
              sender: sender,
              isFromMe: isFromMe,
              date: date,
              associatedMessageID: messageID
            ))
        }
      }
      return reactions
    }
  }

  /// Extract custom emoji from reaction message text like "Reacted 🎉 to "original message""
  func extractCustomEmoji(from text: String) -> String? {
    // Format: "Reacted X to "..." where X is the emoji. Fallback to first emoji in text.
    guard
      let reactedRange = text.range(of: "Reacted "),
      let toRange = text.range(of: " to ", range: reactedRange.upperBound..<text.endIndex)
    else {
      return extractFirstEmoji(from: text)
    }
    let emoji = String(text[reactedRange.upperBound..<toRange.lowerBound])
    return emoji.isEmpty ? extractFirstEmoji(from: text) : emoji
  }

  private func extractFirstEmoji(from text: String) -> String? {
    for character in text {
      if character.unicodeScalars.contains(where: {
        $0.properties.isEmojiPresentation || $0.properties.isEmoji
      }) {
        return String(character)
      }
    }
    return nil
  }

  private struct ReactionKey: Hashable {
    let sender: String
    let isFromMe: Bool
    let reactionType: ReactionType

    static func reindex(reactions: [Reaction]) -> [ReactionKey: Int] {
      var index: [ReactionKey: Int] = [:]
      for (offset, reaction) in reactions.enumerated() {
        let key = ReactionKey(
          sender: reaction.sender,
          isFromMe: reaction.isFromMe,
          reactionType: reaction.reactionType
        )
        index[key] = offset
      }
      return index
    }
  }
}
