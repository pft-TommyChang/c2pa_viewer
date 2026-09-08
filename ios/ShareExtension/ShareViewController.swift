import UniformTypeIdentifiers
import UIKit

private final class ImportCompletionGate {
  private let lock = NSLock()
  private var completed = false
  private let completion: (Result<URL, Error>) -> Void

  init(completion: @escaping (Result<URL, Error>) -> Void) {
    self.completion = completion
  }

  func success(_ url: URL) {
    finish(.success(url))
  }

  func failure(_ error: Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<URL, Error>) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    lock.unlock()
    completion(result)
  }
}

final class ShareViewController: UIViewController {
  private let containingAppURL = URL(string: "c2pa-viewer://shared-media")!
  private let processingLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Importing into Perfect C2PA..."
    label.font = .preferredFont(forTextStyle: .body)
    label.textAlignment = .center
    label.numberOfLines = 0
    return label
  }()
  private let doneButton: UIButton = {
    var configuration = UIButton.Configuration.filled()
    configuration.title = "Open Perfect C2PA"
    let button = UIButton(configuration: configuration)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isHidden = true
    return button
  }()

  private var didStartImport = false
  private var didCompleteExtension = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    view.addSubview(processingLabel)
    view.addSubview(doneButton)
    doneButton.addTarget(self, action: #selector(finishRequest), for: .touchUpInside)
    NSLayoutConstraint.activate([
      processingLabel.leadingAnchor.constraint(
        equalTo: view.layoutMarginsGuide.leadingAnchor
      ),
      processingLabel.trailingAnchor.constraint(
        equalTo: view.layoutMarginsGuide.trailingAnchor
      ),
      processingLabel.centerYAnchor.constraint(
        equalTo: view.centerYAnchor,
        constant: -24
      ),
      doneButton.topAnchor.constraint(
        equalTo: processingLabel.bottomAnchor,
        constant: 20
      ),
      doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didStartImport else { return }
    didStartImport = true

    importSharedMedia()
  }

  private func importSharedMedia() {
    guard let inboxURL = SharedMediaQueue.inboxDirectoryURL(createIfNeeded: true)
    else {
      showCompletion(message: "Unable to prepare the import folder.")
      return
    }

    let providers = sharedItemProviders()
    guard !providers.isEmpty else {
      showCompletion(message: "No supported photos or videos were shared.")
      return
    }

    processingLabel.text = "Importing 1 of \(providers.count)..."
    importProvider(
      providers,
      at: 0,
      importedCount: 0,
      inboxURL: inboxURL
    )
  }

  private func importProvider(
    _ providers: [NSItemProvider],
    at index: Int,
    importedCount: Int,
    inboxURL: URL
  ) {
    guard index < providers.count else {
      finishImport(importedCount: importedCount)
      return
    }

    processingLabel.text = "Importing \(index + 1) of \(providers.count)..."
    copyProviderToInbox(providers[index], inboxURL: inboxURL) {
      [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success:
          self.importProvider(
            providers,
            at: index + 1,
            importedCount: importedCount + 1,
            inboxURL: inboxURL
          )
        case let .failure(error):
          debugPrint("Failed to import shared media item: \(error)")
          self.importProvider(
            providers,
            at: index + 1,
            importedCount: importedCount,
            inboxURL: inboxURL
          )
        }
      }
    }
  }

  private func finishImport(importedCount: Int) {
    guard importedCount > 0 else {
      showCompletion(message: "Unable to import the shared files.")
      return
    }

    let fileWord = importedCount == 1 ? "file" : "files"
    showCompletion(
      message: "Imported \(importedCount) \(fileWord). Open Perfect C2PA to view."
    )

    // The files are already in the App Group inbox. Use the same responder-chain
    // handoff used by YCV to foreground the containing app from a Share
    // Extension. The public NSExtensionContext API is not honored reliably by
    // this extension point on the target iOS versions.
    openContainingApp()
  }

  private func sharedItemProviders() -> [NSItemProvider] {
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    return items
      .flatMap { $0.attachments ?? [] }
      .filter(isSupportedProvider(_:))
  }

  private func isSupportedProvider(_ provider: NSItemProvider) -> Bool {
    provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
      || provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
  }

  private func copyProviderToInbox(
    _ provider: NSItemProvider,
    inboxURL: URL,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let contentType: UTType = provider.hasItemConformingToTypeIdentifier(
      UTType.movie.identifier
    )
      ? .movie
      : .image
    let typeIdentifier = provider.registeredTypeIdentifiers.first {
      guard let type = UTType($0) else { return false }
      return type.conforms(to: contentType)
        && type.preferredFilenameExtension != nil
    } ?? contentType.identifier
    let representationType = UTType(typeIdentifier) ?? contentType
    let suggestedName = provider.suggestedName

    let gate = ImportCompletionGate(completion: completion)
    let timeout = DispatchWorkItem {
      gate.failure(Self.providerTimeoutError)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)

    provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) {
      [weak self] item, error in
      timeout.cancel()
      if error != nil {
        self?.loadDataFallback(
          from: provider,
          typeIdentifier: typeIdentifier,
          suggestedName: suggestedName,
          contentType: contentType,
          inboxURL: inboxURL,
          completion: gate
        )
        return
      }

      do {
        guard let self else { throw Self.missingProviderFileError }
        let destinationURL: URL
        if let sourceURL = item as? URL {
          destinationURL = try self.copySharedFile(
            from: sourceURL,
            suggestedName: suggestedName,
            contentType: representationType,
            inboxURL: inboxURL
          )
        } else if let sourceURL = item as? NSURL {
          destinationURL = try self.copySharedFile(
            from: sourceURL as URL,
            suggestedName: suggestedName,
            contentType: representationType,
            inboxURL: inboxURL
          )
        } else if let data = item as? Data {
          destinationURL = try self.writeSharedData(
            data,
            suggestedName: suggestedName,
            contentType: representationType,
            inboxURL: inboxURL
          )
        } else {
          throw Self.missingProviderFileError
        }
        gate.success(destinationURL)
      } catch {
        self?.loadDataFallback(
          from: provider,
          typeIdentifier: typeIdentifier,
          suggestedName: suggestedName,
          contentType: representationType,
          inboxURL: inboxURL,
          completion: gate
        )
      }
    }
  }

  private func loadDataFallback(
    from provider: NSItemProvider,
    typeIdentifier: String,
    suggestedName: String?,
    contentType: UTType,
    inboxURL: URL,
    completion: ImportCompletionGate
  ) {
    let timeout = DispatchWorkItem {
      completion.failure(Self.providerTimeoutError)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
    provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) {
      [weak self] data, error in
      timeout.cancel()
      guard let data, error == nil else {
        completion.failure(error ?? Self.missingProviderFileError)
        return
      }
      do {
        guard let self else { throw Self.missingProviderFileError }
        let representationType = UTType(typeIdentifier) ?? contentType
        completion.success(try self.writeSharedData(
          data,
          suggestedName: suggestedName,
          contentType: representationType,
          inboxURL: inboxURL
        ))
      } catch {
        completion.failure(error)
      }
    }
  }

  private static let providerTimeoutError = NSError(
    domain: "ShareExtension",
    code: 2,
    userInfo: [NSLocalizedDescriptionKey: "The shared item timed out."]
  )

  private static let missingProviderFileError = NSError(
    domain: "ShareExtension",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Shared item did not provide a file."]
  )

  private func copySharedFile(
    from sourceURL: URL,
    suggestedName: String?,
    contentType: UTType,
    inboxURL: URL
  ) throws -> URL {
    let detectedType = contentType.preferredFilenameExtension == nil
      ? detectedMediaType(in: sourceURL, declaredType: contentType)
      : contentType
    let extensionSuffix = preferredExtension(
      sourceURL: sourceURL,
      suggestedName: suggestedName,
      contentType: detectedType
    )
    let destinationURL = inboxURL.appendingPathComponent(
      "\(UUID().uuidString).\(extensionSuffix)",
      isDirectory: false
    )
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private func detectedMediaType(in sourceURL: URL, declaredType: UTType) -> UTType {
    guard let handle = try? FileHandle(forReadingFrom: sourceURL) else {
      return declaredType
    }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 16) else {
      return declaredType
    }
    return detectedMediaType(in: data, declaredType: declaredType)
  }

  private func writeSharedData(
    _ data: Data,
    suggestedName: String?,
    contentType: UTType,
    inboxURL: URL
  ) throws -> URL {
    let detectedType = detectedMediaType(
      in: data,
      declaredType: contentType
    )
    let extensionSuffix = preferredExtension(
      sourceURL: URL(fileURLWithPath: ""),
      suggestedName: suggestedName,
      contentType: detectedType
    )
    let destinationURL = inboxURL.appendingPathComponent(
      "\(UUID().uuidString).\(extensionSuffix)",
      isDirectory: false
    )
    try data.write(to: destinationURL, options: .atomic)
    return destinationURL
  }

  private func detectedMediaType(in data: Data, declaredType: UTType) -> UTType {
    if declaredType.preferredFilenameExtension != nil {
      return declaredType
    }

    let bytes = [UInt8](data.prefix(16))
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
      return .jpeg
    }
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
      return .png
    }
    if bytes.count >= 12,
      bytes[0..<4].elementsEqual([0x52, 0x49, 0x46, 0x46]),
      bytes[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50])
    {
      return .webP
    }
    if bytes.count >= 12,
      bytes[4..<8].elementsEqual([0x66, 0x74, 0x79, 0x70])
    {
      let brand = String(bytes: bytes[8..<12], encoding: .ascii)
      if brand == "heic" || brand == "heix" || brand == "hevc" || brand == "hevx" {
        return .heic
      }
      if brand == "qt  " {
        return .quickTimeMovie
      }
      return .mpeg4Movie
    }

    return declaredType.conforms(to: .movie) ? .mpeg4Movie : .jpeg
  }

  private func preferredExtension(
    sourceURL: URL,
    suggestedName: String?,
    contentType: UTType
  ) -> String {
    let sourceExtension = sourceURL.pathExtension.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let ignoredExtensions = Set(["dat", "tmp", "bin"])
    if !sourceExtension.isEmpty && !ignoredExtensions.contains(sourceExtension.lowercased()) {
      return sourceExtension.lowercased()
    }

    if let suggestedExtension = suggestedName?
      .split(separator: ".")
      .last,
      !suggestedExtension.isEmpty,
      !ignoredExtensions.contains(suggestedExtension.lowercased())
    {
      return suggestedExtension.lowercased()
    }

    if let preferredExtension = contentType.preferredFilenameExtension {
      return preferredExtension
    }
    return contentType.conforms(to: .movie) ? "mp4" : "jpg"
  }

  private func showCompletion(message: String) {
    processingLabel.text = message
    doneButton.isHidden = false
  }

  @objc private func finishRequest() {
    openContainingApp()
  }

  private func openContainingApp() {
    var responder: UIResponder? = self
    while let currentResponder = responder {
      if let application = currentResponder as? UIApplication {
        application.open(containingAppURL, options: [:])
        debugPrint("Containing app opened through responder chain")
        completeExtensionRequest()
        return
      }
      responder = currentResponder.next
    }

    // Keep the supported API as a fallback for hosts where the responder
    // chain does not expose UIApplication.
    extensionContext?.open(containingAppURL) { [weak self] opened in
      debugPrint("Containing app open fallback request: \(opened)")
      if opened {
        self?.completeExtensionRequest()
      }
    }
  }

  private func completeExtensionRequest() {
    guard !didCompleteExtension else { return }
    didCompleteExtension = true
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }
}
