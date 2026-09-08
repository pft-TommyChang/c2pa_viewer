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
    mediaExtension(for: url) != nil
  }

  private func creationDateCompare(_ lhs: URL, _ rhs: URL) -> Bool {
    let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?
      .creationDate ?? .distantPast
    let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?
      .creationDate ?? .distantPast
    return lhsDate < rhsDate
  }

  private func uniqueTemporaryURL(for sourceURL: URL, directory: URL) -> URL {
    let ext = mediaExtension(for: sourceURL) ?? sourceURL.pathExtension
    let filename = UUID().uuidString
    let component = ext.isEmpty ? filename : "\(filename).\(ext)"
    return directory.appendingPathComponent(component, isDirectory: false)
  }

  private func mediaExtension(for url: URL) -> String? {
    let sourceExtension = url.pathExtension.lowercased()
    if supportedExtensions.contains(sourceExtension) {
      return sourceExtension
    }

    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 16) else {
      return nil
    }
    let bytes = [UInt8](data)

    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
      return "jpg"
    }
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
      return "png"
    }
    if bytes.count >= 12,
      bytes[0..<4].elementsEqual([0x52, 0x49, 0x46, 0x46]),
      bytes[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50])
    {
      return "webp"
    }
    if bytes.count >= 12,
      bytes[4..<8].elementsEqual([0x66, 0x74, 0x79, 0x70])
    {
      let brand = String(bytes: bytes[8..<12], encoding: .ascii)
      if brand == "heic" || brand == "heix" || brand == "hevc" || brand == "hevx" {
        return "heic"
      }
      if brand == "qt  " {
        return "mov"
      }
      return "mp4"
    }

    return nil
  }
}
