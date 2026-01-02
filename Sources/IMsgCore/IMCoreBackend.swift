import Darwin
import Foundation
import ObjectiveC

@_silgen_name("objc_msgSend")
private func objc_msgSend(_ target: AnyObject, _ selector: Selector, ...) -> AnyObject?

enum IMCoreBackend {
  private static let allowEnvKey = "IMSG_ALLOW_PRIVATE"
  private static let replyAssociatedMessageType = 1000

  static func send(_ options: MessageSendOptions) throws {
    guard isPrivateAllowed() else {
      throw IMsgError.privateApiFailure("Set \(allowEnvKey)=1 to enable IMCore mode.")
    }
    if !options.attachmentPath.isEmpty {
      throw IMsgError.privateApiFailure("IMCore send does not support attachments yet.")
    }
    try loadFrameworks()
    guard let registry = chatRegistry() else {
      throw IMsgError.privateApiFailure("Unable to load IMChatRegistry.")
    }

    let chat: AnyObject?
    let chatTarget = options.chatIdentifier.isEmpty ? options.chatGUID : options.chatIdentifier
    if !chatTarget.isEmpty {
      chat = callObject(registry, "existingChatWithIdentifier:", chatTarget as NSString)
        ?? callObject(registry, "existingChatWithGUID:", chatTarget as NSString)
        ?? callObject(registry, "chatWithHandle:", chatTarget as NSString)
    } else {
      chat = callObject(registry, "chatWithHandle:", options.recipient as NSString)
        ?? callObject(registry, "existingChatWithHandle:", options.recipient as NSString)
    }
    guard let chat else {
      throw IMsgError.privateApiFailure("Unable to resolve IMChat for target.")
    }

    guard let message = buildMessage(options: options) else {
      throw IMsgError.privateApiFailure("Unable to construct IMMessage.")
    }

    let sendSel = Selector(("_sendMessage:adjustingSender:shouldQueue:"))
    if chat.responds(to: sendSel) {
      callVoid(chat, sendSel, message, true, true)
      return
    }

    let fallbackSel = Selector(("_sendMessage:withAccount:adjustingSender:shouldQueue:"))
    if chat.responds(to: fallbackSel) {
      let account = callObject(chat, "account")
      callVoid(chat, fallbackSel, message, account, true, true)
      return
    }

    throw IMsgError.privateApiFailure("IMChat send selector unavailable.")
  }

  private static func buildMessage(options: MessageSendOptions) -> AnyObject? {
    guard let cls = NSClassFromString("IMMessage") as? NSObject.Type else { return nil }
    var message: AnyObject = cls.alloc()

    let sel = Selector(("initWithSender:time:text:fileTransferGUIDs:flags:error:guid:subject:threadIdentifier:"))
    let time = Date().timeIntervalSince1970
    let text = options.text as NSString
    let fileTransfers: [Any] = []
    var error: NSError?
    let guid: NSString? = nil
    let subject: NSString? = nil
    let threadIdentifier = options.replyToGUID.isEmpty ? nil : options.replyToGUID as NSString

    guard message.responds(to: sel) else { return nil }
    let initFn = unsafeBitCast(
      objc_msgSend,
      to: (@convention(c)
          (AnyObject, Selector, AnyObject?, Double, AnyObject?, AnyObject?, UInt64,
           UnsafeMutablePointer<NSError?>?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?).self
    )
    if let created = initFn(
      message,
      sel,
      nil,
      time,
      text,
      fileTransfers as NSArray,
      0,
      &error,
      guid,
      subject,
      threadIdentifier
    ) {
      message = created
    } else {
      return nil
    }

    if !options.replyToGUID.isEmpty {
      message.setValue(options.replyToGUID, forKey: "associatedMessageGUID")
      message.setValue(NSNumber(value: replyAssociatedMessageType), forKey: "associatedMessageType")
      message.setValue(options.replyToGUID, forKey: "threadIdentifier")
    }

    return message
  }

  private static func isPrivateAllowed() -> Bool {
    return ProcessInfo.processInfo.environment[allowEnvKey] == "1"
  }

  private static func loadFrameworks() throws {
    let frameworks = [
      "/System/Library/PrivateFrameworks/IMCore.framework/IMCore",
      "/System/Library/PrivateFrameworks/IMFoundation.framework/IMFoundation",
      "/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore",
      "/System/Library/PrivateFrameworks/IMSharedUtilities.framework/IMSharedUtilities",
    ]
    for path in frameworks {
      if dlopen(path, RTLD_LAZY) == nil {
        if let err = dlerror() {
          throw IMsgError.privateApiFailure(
            "dlopen failed for \(path): \(String(cString: err))")
        }
        throw IMsgError.privateApiFailure("dlopen failed for \(path)")
      }
    }
  }

  private static func chatRegistry() -> AnyObject? {
    guard let cls = NSClassFromString("IMChatRegistry") as AnyObject? else { return nil }
    return callObject(cls, "sharedInstance")
      ?? callObject(cls, "sharedRegistry")
      ?? callObject(cls, "sharedRegistryIfAvailable")
  }

  private static func callObject(
    _ target: AnyObject,
    _ selectorName: String,
    _ arg: AnyObject? = nil
  ) -> AnyObject? {
    let selector = Selector(selectorName)
    guard target.responds(to: selector) else { return nil }
    let fn = unsafeBitCast(
      objc_msgSend,
      to: (@convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?).self
    )
    return fn(target, selector, arg)
  }

  private static func callVoid(
    _ target: AnyObject,
    _ selector: Selector,
    _ message: AnyObject,
    _ adjustingSender: Bool,
    _ shouldQueue: Bool
  ) {
    let fn = unsafeBitCast(
      objc_msgSend,
      to: (@convention(c) (AnyObject, Selector, AnyObject, Bool, Bool) -> Void).self
    )
    fn(target, selector, message, adjustingSender, shouldQueue)
  }

  private static func callVoid(
    _ target: AnyObject,
    _ selector: Selector,
    _ message: AnyObject,
    _ account: AnyObject?,
    _ adjustingSender: Bool,
    _ shouldQueue: Bool
  ) {
    let fn = unsafeBitCast(
      objc_msgSend,
      to: (@convention(c) (AnyObject, Selector, AnyObject, AnyObject?, Bool, Bool) -> Void).self
    )
    fn(target, selector, message, account, adjustingSender, shouldQueue)
  }
}
