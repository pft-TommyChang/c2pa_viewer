import C2PA
import Flutter
import Photos
import PhotosUI
import UIKit

// C2PA native handler — registered by AppDelegate onto the Flutter engine's
// binary messenger. Requires c2pa-swift added via Xcode > Add Package
// Dependencies: https://github.com/contentauth/c2pa-swift.git (tag 0.0.12+)
//
// Supported methods (all called on a background thread):
//   signFile   – sign source → dest, supports images + video
//   readManifest – return raw manifest JSON string (nil if no C2PA data)
//   pickOriginalMedia   – present PHPicker and export selected asset's original binary to a temp path
//   removeFile          – strip C2PA from a file (images: re-encode; video: binary box strip)
//   saveToPhotoLibrary – save a signed image/video without re-encoding it

@available(iOS 16, *)
final class C2paNativeHandler: NSObject {

  static let channelName = "c2pa_native"

  // Stores the pending FlutterResult while PHPickerViewController is presented.
  private var pendingPickResult: FlutterResult?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let handler = C2paNativeHandler()
    channel.setMethodCallHandler { call, result in
      // Dispatch to background thread so we don't block the UI.
      DispatchQueue.global(qos: .userInitiated).async {
        handler.handle(call, result: result)
      }
    }
  }

  // MARK: - Dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // pickOriginalMedia takes no arguments — dispatch before the args guard.
    if call.method == "pickOriginalMedia" {
      pickOriginalMedia(result: result)
      return
    }

    guard let args = call.arguments as? [String: Any] else {
      complete(
        result,
        with: FlutterError(
          code: "BAD_ARGS",
          message: "Expected dictionary args",
          details: nil
        )
      )
      return
    }
    switch call.method {
    case "signFile":
      signFile(args: args, result: result)
    case "readManifest":
      readManifest(args: args, result: result)
    case "removeFile":
      removeFile(args: args, result: result)
    case "saveToPhotoLibrary":
      saveToPhotoLibrary(args: args, result: result)
    default:
      complete(result, with: FlutterMethodNotImplemented)
    }
  }

  // MARK: - pickOriginalMedia

  /// Presents PHPickerViewController and exports the selected asset's original binary
  /// (HEIC, JPEG, MOV, MP4, …) to a temporary file, preserving all embedded metadata
  /// including C2PA. Returns the temp file path, or nil when the user cancels.
  private func pickOriginalMedia(result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      var config = PHPickerConfiguration()  // No photoLibrary — no extra permission needed.
      config.selectionLimit = 1
      config.filter = .any(of: [.images, .videos])

      let picker = PHPickerViewController(configuration: config)
      picker.delegate = self
      self.pendingPickResult = result

      guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
        let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
      else {
        self.complete(result, with: FlutterError(
          code: "NO_ROOT_VC", message: "No active root view controller", details: nil
        ))
        return
      }
      var topVC = rootVC
      while let presented = topVC.presentedViewController { topVC = presented }
      topVC.present(picker, animated: true)
    }
  }

  // MARK: - signFile

  private func signFile(args: [String: Any], result: @escaping FlutterResult) {
    guard
      let sourcePath  = args["sourcePath"]  as? String,
      let outputPath  = args["outputPath"]  as? String,
      let mimeType    = args["mimeType"]    as? String,
      let certPem     = args["certPem"]     as? String,
      let keyPem      = args["keyPem"]      as? String,
      let title       = args["title"]       as? String,
      let mode        = args["mode"]        as? String
    else {
      complete(
        result,
        with: FlutterError(
          code: "BAD_ARGS",
          message: "Missing required signFile args",
          details: nil
        )
      )
      return
    }

    let manifestJSON = buildManifestJSON(title: title, mimeType: mimeType)

    do {
      let signerInfo = SignerInfo(
        algorithm: .es256,
        certificatePEM: certPem,
        privateKeyPEM: keyPem,
        tsa: nil
      )
      let source = URL(fileURLWithPath: sourcePath)
      let dest   = URL(fileURLWithPath: outputPath)

      // Ensure output directory exists
      try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      let sourceStream = try Stream(readFrom: source)
      let destinationStream = try Stream(writeTo: dest)
      let signer = try Signer(info: signerInfo)
      let builder = try Builder(manifestJSON: manifestJSON)
      switch mode {
      case "add":
        if hasManifest(source, format: mimeType) {
          // Preserve the existing provenance as the single parent ingredient.
          try builder.setIntent(.edit)
          let ingredientStream = try Stream(readFrom: source)
          try builder.addIngredient(
            json: buildParentIngredientJSON(
              title: source.lastPathComponent,
              mimeType: mimeType
            ),
            format: mimeType,
            from: ingredientStream
          )
        } else {
          // An unsigned source starts its first provenance chain.
          try builder.setIntent(.create(.digitalCreation))
        }
      case "replace":
        // Start a new provenance chain rather than retaining the old manifest
        // as a parent ingredient.
        try builder.setIntent(.create(.digitalCreation))
      default:
        throw NativeC2paError.unsupportedWriteMode(mode)
      }
      _ = try builder.sign(
        format: mimeType,
        source: sourceStream,
        destination: destinationStream,
        signer: signer
      )
      complete(result, with: nil)
    } catch {
      complete(
        result,
        with: FlutterError(
          code: "SIGN_FAILED",
          message: error.localizedDescription,
          details: "\(error)"
        )
      )
    }
  }

  // MARK: - removeFile

  /// Strips all C2PA data from the source and writes the clean file to outputPath.
  /// Images: re-encoded via CGImageSource/Destination (drops all metadata, no quality flag needed).
  /// Video (mp4/mov): binary box-level strip of top-level uuid/c2pa boxes.
  private func removeFile(args: [String: Any], result: @escaping FlutterResult) {
    guard
      let sourcePath = args["sourcePath"] as? String,
      let outputPath = args["outputPath"] as? String
    else {
      complete(result, with: FlutterError(code: "BAD_ARGS", message: "Missing sourcePath or outputPath", details: nil))
      return
    }

    let source = URL(fileURLWithPath: sourcePath)
    let dest   = URL(fileURLWithPath: outputPath)

    do {
      try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if isVideo(source) {
        try removeC2paFromVideo(source, to: dest)
      } else {
        try removeC2paFromImage(source, to: dest)
      }
      complete(result, with: nil)
    } catch {
      complete(result, with: FlutterError(
        code: "REMOVE_FAILED",
        message: error.localizedDescription,
        details: "\(error)"
      ))
    }
  }

  /// Re-encodes the image without any metadata, effectively stripping C2PA and all other metadata.
  private func removeC2paFromImage(_ source: URL, to destination: URL) throws {
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
      throw NativeC2paError.removalFailed("Could not read image at \(source.lastPathComponent)")
    }
    let uti = CGImageSourceGetType(imageSource) ?? ("public.jpeg" as CFString)
    guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, uti, 1, nil) else {
      throw NativeC2paError.removalFailed("Could not create output image destination")
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
      throw NativeC2paError.removalFailed("Could not decode image pixels")
    }
    // Adding the raw CGImage (pixel data only) without the original metadata
    // properties means no EXIF, XMP, or C2PA data is written to the output.
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw NativeC2paError.removalFailed("Could not write output image")
    }
  }

  /// Strips top-level C2PA uuid boxes and c2pa boxes from an MP4/MOV file
  /// by parsing ISO Base Media File Format (ISOBMFF) boxes at the file level.
  private func removeC2paFromVideo(_ source: URL, to destination: URL) throws {
    let data = try Data(contentsOf: source)
    var output = Data()
    var offset = 0

    // C2PA manifest UUID in ISOBMFF: d8fec3d6-1d34-f040-b1ba-bb4be5dc35ca
    let c2paUUID: [UInt8] = [
      0xd8, 0xfe, 0xc3, 0xd6, 0x1d, 0x34, 0xf0, 0x40,
      0xb1, 0xba, 0xbb, 0x4b, 0xe5, 0xdc, 0x35, 0xca,
    ]

    while offset + 8 <= data.count {
      // Read 4-byte big-endian box size
      let b = data[offset..<(offset + 4)]
      let rawSize = (Int(b[b.startIndex]) << 24) | (Int(b[b.startIndex+1]) << 16)
                  | (Int(b[b.startIndex+2]) << 8)  |  Int(b[b.startIndex+3])

      let typeBytes = data[(offset+4)..<(offset+8)]
      let boxType   = String(bytes: typeBytes, encoding: .ascii) ?? ""

      // Determine box total size and header size from rawSize field.
      var totalSize: Int
      var headerSize: Int
      if rawSize == 1 {
        // Extended 64-bit size stored in bytes 8-15
        guard offset + 16 <= data.count else { break }
        let eb = data[(offset+8)..<(offset+16)]
        totalSize  = (Int(eb[eb.startIndex])   << 56) | (Int(eb[eb.startIndex+1]) << 48)
                   | (Int(eb[eb.startIndex+2]) << 40) | (Int(eb[eb.startIndex+3]) << 32)
                   | (Int(eb[eb.startIndex+4]) << 24) | (Int(eb[eb.startIndex+5]) << 16)
                   | (Int(eb[eb.startIndex+6]) <<  8) |  Int(eb[eb.startIndex+7])
        headerSize = 16
      } else if rawSize == 0 {
        // Box extends to end of file
        totalSize  = data.count - offset
        headerSize = 8
      } else {
        totalSize  = rawSize
        headerSize = 8
      }

      guard totalSize > 0, offset + totalSize <= data.count else { break }

      // Decide whether to skip this box
      var skip = (boxType == "c2pa")
      if !skip && boxType == "uuid" && offset + headerSize + 16 <= data.count {
        let uuidStart = offset + headerSize
        let boxUUID   = Array(data[uuidStart..<(uuidStart + 16)])
        skip = (boxUUID == c2paUUID)
      }

      if !skip {
        output.append(data[offset..<(offset + totalSize)])
      }
      offset += totalSize
    }

    try output.write(to: destination)
  }

  // MARK: - saveToPhotoLibrary

  private func saveToPhotoLibrary(args: [String: Any], result: @escaping FlutterResult) {
    guard let filePath = args["path"] as? String else {
      complete(
        result,
        with: FlutterError(code: "BAD_ARGS", message: "Missing path", details: nil)
      )
      return
    }

    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      complete(
        result,
        with: FlutterError(
          code: "FILE_NOT_FOUND",
          message: "The signed media file does not exist.",
          details: filePath
        )
      )
      return
    }

    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
      guard let self else { return }
      guard status == .authorized || status == .limited else {
        self.complete(
          result,
          with: FlutterError(
            code: "PHOTO_PERMISSION_DENIED",
            message: "Photo Library add permission was denied.",
            details: nil
          )
        )
        return
      }

      PHPhotoLibrary.shared().performChanges {
        if self.isVideo(fileURL) {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        } else {
          // Use resource-based API to preserve exact binary content (including C2PA metadata).
          // creationRequestForAssetFromImage re-encodes the image and strips embedded metadata.
          let creationRequest = PHAssetCreationRequest.forAsset()
          let resourceOptions = PHAssetResourceCreationOptions()
          resourceOptions.shouldMoveFile = false
          creationRequest.addResource(with: .photo, fileURL: fileURL, options: resourceOptions)
        }
      } completionHandler: { success, error in
        if success {
          self.complete(result, with: nil)
        } else {
          self.complete(
            result,
            with: FlutterError(
              code: "PHOTO_SAVE_FAILED",
              message: error?.localizedDescription ?? "Could not save media to Photos.",
              details: error.map { "\($0)" }
            )
          )
        }
      }
    }
  }

  // MARK: - readManifest

  private func readManifest(args: [String: Any], result: @escaping FlutterResult) {
    guard let filePath = args["path"] as? String else {
      complete(
        result,
        with: FlutterError(code: "BAD_ARGS", message: "Missing path", details: nil)
      )
      return
    }
    do {
      let fileURL = URL(fileURLWithPath: filePath)
      guard let format = mimeType(for: fileURL) else {
        complete(
          result,
          with: FlutterError(
            code: "UNSUPPORTED_FORMAT",
            message: "Unsupported media extension: .\(fileURL.pathExtension)",
            details: nil
          )
        )
        return
      }
      let stream = try Stream(readFrom: fileURL)
      let reader = try Reader(format: format, stream: stream)
      let json = try reader.json()
      complete(result, with: json)
    } catch {
      // File has no C2PA data — return nil, not an error
      complete(result, with: nil)
    }
  }

  private func complete(_ result: @escaping FlutterResult, with value: Any?) {
    DispatchQueue.main.async {
      result(value)
    }
  }

  private func mimeType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg":
      return "image/jpeg"
    case "png":
      return "image/png"
    case "webp":
      return "image/webp"
    case "tif", "tiff":
      return "image/tiff"
    case "heic":
      return "image/heic"
    case "mp4":
      return "video/mp4"
    case "mov":
      return "video/quicktime"
    default:
      return nil
    }
  }

  private func isVideo(_ url: URL) -> Bool {
    ["mp4", "mov"].contains(url.pathExtension.lowercased())
  }

  private func hasManifest(_ url: URL, format: String) -> Bool {
    do {
      let stream = try Stream(readFrom: url)
      let reader = try Reader(format: format, stream: stream)
      _ = try reader.json()
      return true
    } catch {
      return false
    }
  }

  // MARK: - Manifest JSON builder

  private func buildManifestJSON(title: String, mimeType: String) -> String {
    // Escape title for safe JSON embedding
    let safeTitle = title
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    {
      "claim_generator": "Perfect C2PA Mobile/1.0",
      "claim_generator_info": [{"name": "Perfect C2PA Mobile", "version": "1.0"}],
      "title": "\(safeTitle)",
      "format": "\(mimeType)",
      "assertions": [
        {
          "label": "c2pa.actions",
          "data": {
            "actions": [
              {
                "action": "c2pa.edited",
                "softwareAgent": "Perfect C2PA Mobile/1.0",
                "description": "Signed on mobile with Perfect C2PA"
              }
            ]
          }
        }
      ]
    }
    """
  }

  private func buildParentIngredientJSON(title: String, mimeType: String) -> String {
    let safeTitle = title
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    {
      "title": "\(safeTitle)",
      "format": "\(mimeType)",
      "relationship": "parentOf"
    }
    """
  }
}


// MARK: - PHPickerViewControllerDelegate

@available(iOS 16, *)
extension C2paNativeHandler: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let pendingResult = pendingPickResult else { return }
    pendingPickResult = nil

    guard let item = results.first else {
      // User cancelled — return nil (not an error).
      complete(pendingResult, with: nil)
      return
    }

    // Prefer the asset's native format to avoid any transcoding that would strip C2PA.
    // Images: try HEIC before JPEG so we never trigger a lossy conversion.
    let preferredTypes = [
      "public.heic", "public.heif",
      "public.jpeg",
      "public.png",
      "public.tiff",
      "org.webmproject.webp",
      "com.apple.quicktime-movie",
      "public.mpeg-4",
    ]
    let registered = item.itemProvider.registeredTypeIdentifiers
    let uti = preferredTypes.first { registered.contains($0) } ?? registered.first

    guard let uti else {
      complete(pendingResult, with: FlutterError(
        code: "UNSUPPORTED_TYPE",
        message: "No supported type found for selected item",
        details: registered.joined(separator: ", ")
      ))
      return
    }

    // loadFileRepresentation returns a COPY of the original binary; the temp URL
    // is valid only inside this closure so we copy it to our own temp file first.
    item.itemProvider.loadFileRepresentation(forTypeIdentifier: uti) { [weak self] url, error in
      guard let self else { return }
      if let error {
        self.complete(pendingResult, with: FlutterError(
          code: "LOAD_FAILED",
          message: error.localizedDescription,
          details: "\(error)"
        ))
        return
      }
      guard let url else {
        self.complete(pendingResult, with: nil)
        return
      }
      let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("c2pa_pick_\(UUID().uuidString)")
        .appendingPathExtension(url.pathExtension)
      do {
        try FileManager.default.copyItem(at: url, to: dest)
        self.complete(pendingResult, with: dest.path)
      } catch {
        self.complete(pendingResult, with: FlutterError(
          code: "COPY_FAILED",
          message: error.localizedDescription,
          details: "\(error)"
        ))
      }
    }
  }
}

private enum NativeC2paError: LocalizedError {
  case unsupportedWriteMode(String)
  case removalFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedWriteMode(let mode):
      return "Unsupported C2PA write mode: \(mode)"
    case .removalFailed(let reason):
      return "C2PA removal failed: \(reason)"
    }
  }
}
