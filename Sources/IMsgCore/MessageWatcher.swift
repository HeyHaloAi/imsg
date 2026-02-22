import Foundation

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var batchLimit: Int
  /// When true, reaction events (tapback add/remove) are included in the stream
  public var includeReactions: Bool

  public init(
    debounceInterval: TimeInterval = 0.25,
    batchLimit: Int = 100,
    includeReactions: Bool = false
  ) {
    self.debounceInterval = debounceInterval
    self.batchLimit = batchLimit
    self.includeReactions = includeReactions
  }
}

public actor MessageWatcher {
  private let store: MessageStore

  public init(store: MessageStore) {
    self.store = store
  }

  public func stream(
    chatID: Int64? = nil,
    sinceRowID: Int64? = nil,
    configuration: MessageWatcherConfiguration = MessageWatcherConfiguration()
  ) -> AsyncThrowingStream<Message, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var cursor = sinceRowID ?? 0
          if cursor == 0 {
            cursor = try await store.maxRowID()
          }

          while Task.isCancelled == false {
            let messages = try await store.messagesAfter(
              afterRowID: cursor,
              chatID: chatID,
              limit: configuration.batchLimit,
              includeReactions: configuration.includeReactions
            )
            for message in messages {
              continuation.yield(message)
              if message.rowID > cursor {
                cursor = message.rowID
              }
            }

            try await Task.sleep(nanoseconds: UInt64(configuration.debounceInterval * 1_000_000_000))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
