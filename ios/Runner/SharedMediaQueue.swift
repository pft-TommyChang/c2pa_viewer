import Foundation

final class SharedMediaQueue {
  static let appGroupIdentifier = "group.com.tommychang.perfectc2pa.shared"
  static let inboxDirectoryName = "SharedMediaInbox"

  private let supportedExtensions: Set<String> = [
    "mp4", "mov", "m4v", "avi", "mkv", "webm",
    "jpg", "jpeg", "png", "webp", "heic", "heif",
  ]

  private let fileManager = FileManager.default

  func consumePendingFiles() -> [String] {
    guard let inboxURL = Self.inboxDirectoryURL(createIfNeeded: false) else {
      return []
    }
    guard
      let fileURLs = try? fileManager.contentsOfDirectory(
        at: inboxURL,
        includingPropertiesForKeys: [.creationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    let sortedURLs = fileURLs
      .filter(isSupportedMediaFile(_:))
      .sorted(by: creationDateCompare(_:_:))
    guard !sortedURLs.isEmpty else { return [] }

    let temporaryDirectory = URL(
      fileURLWithPath: NSTemporaryDirectory(),
      isDirectory: true
    )
    var consumedPaths: [String] = []
    consumedPaths.reserveCapacity(sortedURLs.count)

    for sourceURL in sortedURLs {
      let destinationURL = uniqueTemporaryURL(
        for: sourceURL,
        directory: temporaryDirectory
      )
      do {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        consumedPaths.append(destinationURL.path)
      } catch {
        debugPrint("Failed to move shared media into app sandbox: \(error)")
      }
    }

    return consumedPaths
  }

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

  private func isSupportedMediaFile(_ url: URL) -> Bool {
    supportedExtensions.contains(url.pathExtension.lowercased())
  }

  private func creationDateCompare(_ lhs: URL, _ rhs: URL) -> Bool {
    let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?
      .creationDate ?? .distantPast
    let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?
      .creationDate ?? .distantPast
    return lhsDate < rhsDate
  }

  private func uniqueTemporaryURL(for sourceURL: URL, directory: URL) -> URL {
    let ext = sourceURL.pathExtension
    let filename = UUID().uuidString
    let component = ext.isEmpty ? filename : "\(filename).\(ext)"
    return directory.appendingPathComponent(component, isDirectory: false)
  }
}
