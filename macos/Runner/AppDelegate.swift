import AVFoundation
import Cocoa
import FlutterMacOS

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

  private func probeError(code: String, path: String) -> FlutterError {
    FlutterError(
      code: code,
      message: "Unable to inspect the selected media file.",
      details: path
    )
  }
}
