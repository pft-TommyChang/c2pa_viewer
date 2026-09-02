import AVFoundation
import Cocoa
import FlutterMacOS
import ImageIO

@main
class AppDelegate: FlutterAppDelegate {
  private let mediaOpenChannelName = "c2pa_viewer/media_open"
  private let mediaProbeChannelName = "c2pa_viewer/media_probe"
  private var mediaOpenChannel: FlutterMethodChannel?
  private var pendingOpenFilePaths: [String] = []
  private var securityScopedMediaURLs: [String: [URL]] = [:]

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard
      let flutterViewController = mainFlutterWindow?.contentViewController
        as? FlutterViewController
    else {
      return
    }

    let openChannel = FlutterMethodChannel(
      name: mediaOpenChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    mediaOpenChannel = openChannel
    openChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "consumePendingMediaFiles" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let paths = self?.pendingOpenFilePaths ?? []
      self?.pendingOpenFilePaths.removeAll()
      result(paths)
    }

    let probeChannel = FlutterMethodChannel(
      name: mediaProbeChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    probeChannel.setMethodCallHandler { [weak self] call, result in
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String
      else {
        result(
          FlutterError(
            code: "invalid-arguments",
            message: "Expected a media file path.",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "beginAccessingMedia":
        result(self?.beginAccessingMedia(path: path) ?? false)
      case "endAccessingMedia":
        self?.endAccessingMedia(path: path)
        result(nil)
      case "probeMedia":
        self?.probeMedia(path: path, result: result)
      case "thumbnailForMedia":
        self?.thumbnailForMedia(path: path, result: result)
      case "removeC2paFromMedia":
        guard let outputPath = arguments["outputPath"] as? String else {
          result(
            FlutterError(
              code: "invalid-arguments",
              message: "Expected an output media file path.",
              details: nil
            )
          )
          return
        }
        self?.removeC2paFromMedia(
          path: path,
          outputPath: outputPath,
          result: result
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }

  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    queueOpenedMediaFiles(filenames, application: sender)
    sender.reply(toOpenOrPrint: .success)
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    queueOpenedMediaFiles(
      urls.filter(\.isFileURL).map(\.path),
      application: application
    )
  }

  override func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    true
  }

  override func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    true
  }

  private func queueOpenedMediaFiles(
    _ paths: [String],
    application: NSApplication
  ) {
    for path in paths where !pendingOpenFilePaths.contains(path) {
      pendingOpenFilePaths.append(path)
    }
    guard !paths.isEmpty else { return }
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    mediaOpenChannel?.invokeMethod("mediaFilesOpened", arguments: nil)
  }

  private func probeMedia(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let photoExtensions: Set<String> = [
      "jpg", "jpeg", "png", "webp", "heic", "heif",
    ]
    if photoExtensions.contains(url.pathExtension.lowercased()) {
      guard let image = NSImage(contentsOf: url) else {
        result(probeError(code: "invalid-image", path: path))
        return
      }
      let representation = image.representations.max {
        $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
      }
      result([
        "width": representation?.pixelsWide ?? Int(image.size.width),
        "height": representation?.pixelsHigh ?? Int(image.size.height),
        "durationSeconds": 0,
        "hasAudio": false,
        "isPhoto": true,
      ])
      return
    }

    let asset = AVURLAsset(url: url)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      result(probeError(code: "no-video-track", path: path))
      return
    }
    let transformedSize = videoTrack.naturalSize.applying(
      videoTrack.preferredTransform
    )
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    result([
      "width": Int(abs(transformedSize.width).rounded()),
      "height": Int(abs(transformedSize.height).rounded()),
      "durationSeconds": durationSeconds.isFinite ? durationSeconds : 0,
      "hasAudio": !asset.tracks(withMediaType: .audio).isEmpty,
      "isPhoto": false,
    ])
  }

  private func beginAccessingMedia(path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard url.startAccessingSecurityScopedResource() else { return false }
    securityScopedMediaURLs[path, default: []].append(url)
    return true
  }

  private func endAccessingMedia(path: String) {
    guard var urls = securityScopedMediaURLs[path], let url = urls.popLast()
    else { return }
    url.stopAccessingSecurityScopedResource()
    if urls.isEmpty {
      securityScopedMediaURLs.removeValue(forKey: path)
    } else {
      securityScopedMediaURLs[path] = urls
    }
  }


  private func thumbnailForMedia(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    if let image = NSImage(contentsOf: url),
      let jpegData = thumbnailJPEG(for: image)
    {
      result(FlutterStandardTypedData(bytes: jpegData))
      return
    }
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 512, height: 512)
    let time = CMTime(seconds: 0, preferredTimescale: 600)
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
      _, image, _, status, _ in
      if status == .succeeded, let image = image {
        let nsImage = NSImage(cgImage: image, size: .zero)
        if let jpegData = self.thumbnailJPEG(for: nsImage) {
          result(FlutterStandardTypedData(bytes: jpegData))
          return
        }
      }
      result(nil)
    }
  }

  private func thumbnailJPEG(for image: NSImage) -> Data? {
    guard let tiffData = image.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiffData)
    else { return nil }
    return bitmapRep.representation(
      using: .jpeg,
      properties: [.compressionFactor: 0.75]
    )
  }

  private func removeC2paFromMedia(
    path: String,
    outputPath: String,
    result: @escaping FlutterResult
  ) {
    let sourceURL = URL(fileURLWithPath: path)
    let outputURL = URL(fileURLWithPath: outputPath)
    let photoExtensions: Set<String> = [
      "jpg", "jpeg", "png", "webp", "heic", "heif",
    ]
    if photoExtensions.contains(sourceURL.pathExtension.lowercased()) {
      removeC2paFromImage(
        sourceURL: sourceURL,
        outputURL: outputURL,
        result: result
      )
      return
    }
    removeC2paFromVideo(
      sourceURL: sourceURL,
      outputURL: outputURL,
      result: result
    )
  }

  private func removeC2paFromImage(
    sourceURL: URL,
    outputURL: URL,
    result: FlutterResult
  ) {
    guard
      let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let imageType = CGImageSourceGetType(source),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        imageType,
        1,
        nil
      )
    else {
      result(
        FlutterError(
          code: "c2pa-remove-failed",
          message: "The image could not be rewritten without C2PA.",
          details: sourceURL.path
        )
      )
      return
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      result(
        FlutterError(
          code: "c2pa-remove-failed",
          message: "The image could not be saved without C2PA.",
          details: outputURL.path
        )
      )
      return
    }
    result(nil)
  }

  private func removeC2paFromVideo(
    sourceURL: URL,
    outputURL: URL,
    result: @escaping FlutterResult
  ) {
    let asset = AVURLAsset(url: sourceURL)
    guard
      let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetPassthrough
      ),
      let outputFileType = outputFileType(for: outputURL.pathExtension),
      exportSession.supportedFileTypes.contains(outputFileType)
    else {
      result(
        FlutterError(
          code: "c2pa-remove-unsupported",
          message: "Removing C2PA is not supported for this video format.",
          details: sourceURL.pathExtension
        )
      )
      return
    }
    exportSession.outputURL = outputURL
    exportSession.outputFileType = outputFileType
    exportSession.metadata = []
    exportSession.exportAsynchronously {
      switch exportSession.status {
      case .completed:
        result(nil)
      default:
        result(
          FlutterError(
            code: "c2pa-remove-failed",
            message: "The video could not be rewritten without C2PA.",
            details: exportSession.error?.localizedDescription
          )
        )
      }
    }
  }

  private func outputFileType(for extensionName: String) -> AVFileType? {
    switch extensionName.lowercased() {
    case "mp4", "m4v":
      return .mp4
    case "mov":
      return .mov
    default:
      return nil
    }
  }

  private func probeError(code: String, path: String) -> FlutterError {
    FlutterError(
      code: code,
      message: "Unable to inspect the selected media file.",
      details: path
    )
  }
}
