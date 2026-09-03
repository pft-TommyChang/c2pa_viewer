import Foundation

final class SharedMediaQueue {
  static let appGroupIdentifier = "group.com.tommychang.perfectc2pa.shared"
  static let inboxDirectoryName = "SharedMediaInbox"

  static func inboxDirectoryURL(createIfNeeded: Bool) -> URL? {
    let fileManager = FileManager.default
    guard
      let containerURL = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      return nil
    }

    let inboxURL = containerURL.appendingPathComponent(
      inboxDirectoryName,
      isDirectory: true
    )
    guard createIfNeeded else { return inboxURL }

    do {
      try fileManager.createDirectory(
        at: inboxURL,
        withIntermediateDirectories: true
      )
      return inboxURL
    } catch {
      debugPrint("Failed to create shared media inbox: \(error)")
      return nil
    }
  }
}
