import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
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
    configuration.title = "Done"
    let button = UIButton(configuration: configuration)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isHidden = true
    return button
  }()

  private var didStartImport = false

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

    Task { @MainActor in
      await importSharedMedia()
    }
  }

  private func importSharedMedia() async {
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

    var importedCount = 0
    for provider in providers {
      do {
        _ = try await copyProviderToInbox(provider, inboxURL: inboxURL)
        importedCount += 1
      } catch {
        debugPrint("Failed to import shared media item: \(error)")
      }
    }

    let message = importedCount > 0
      ? "Imported \(importedCount) file\(importedCount == 1 ? "" : "s"). Open Perfect C2PA to view \(importedCount == 1 ? "it" : "them")."
      : "Unable to import the shared files."
    showCompletion(message: message)
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
    inboxURL: URL
  ) async throws -> URL {
    let contentType: UTType = provider.hasItemConformingToTypeIdentifier(
      UTType.movie.identifier
    )
      ? .movie
      : .image
    let suggestedName = provider.suggestedName

    return try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: contentType.identifier) {
        url, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let url else {
          continuation.resume(
            throwing: NSError(
              domain: "ShareExtension",
              code: 1,
              userInfo: [
                NSLocalizedDescriptionKey: "Shared item did not provide a file."
              ]
            )
          )
          return
        }

        do {
          let destinationURL = try self.copySharedFile(
            from: url,
            suggestedName: suggestedName,
            contentType: contentType,
            inboxURL: inboxURL
          )
          continuation.resume(returning: destinationURL)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func copySharedFile(
    from sourceURL: URL,
    suggestedName: String?,
    contentType: UTType,
    inboxURL: URL
  ) throws -> URL {
    let extensionSuffix = preferredExtension(
      sourceURL: sourceURL,
      suggestedName: suggestedName,
      contentType: contentType
    )
    let destinationURL = inboxURL.appendingPathComponent(
      "\(UUID().uuidString).\(extensionSuffix)",
      isDirectory: false
    )
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private func preferredExtension(
    sourceURL: URL,
    suggestedName: String?,
    contentType: UTType
  ) -> String {
    let sourceExtension = sourceURL.pathExtension.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if !sourceExtension.isEmpty {
      return sourceExtension.lowercased()
    }

    if let suggestedExtension = suggestedName?
      .split(separator: ".")
      .last,
      !suggestedExtension.isEmpty
    {
      return suggestedExtension.lowercased()
    }

    return contentType.preferredFilenameExtension ?? "dat"
  }

  private func showCompletion(message: String) {
    processingLabel.text = message
    doneButton.isHidden = false
  }

  @objc private func finishRequest() {
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }
}
