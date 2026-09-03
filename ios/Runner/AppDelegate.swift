import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let mediaOpenChannelName = "c2pa_viewer/media_open"
  private var mediaOpenChannel: FlutterMethodChannel?
  private var pendingOpenFilePaths: [String] = []
  private let sharedMediaQueue = SharedMediaQueue()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    pendingOpenFilePaths.append(contentsOf: sharedMediaQueue.consumePendingFiles())
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    queueOpenedMediaFiles(sharedMediaQueue.consumePendingFiles())
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let mediaOpenRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "MediaOpenChannel"
    ) else {
      assertionFailure("Unable to create the media open Flutter plugin registrar")
      return
    }
    let openChannel = FlutterMethodChannel(
      name: mediaOpenChannelName,
      binaryMessenger: mediaOpenRegistrar.messenger()
    )
    mediaOpenChannel = openChannel
    openChannel.setMethodCallHandler { [weak self] (
      call: FlutterMethodCall,
      result: @escaping FlutterResult
    ) in
      guard call.method == "consumePendingMediaFiles" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let paths = self?.pendingOpenFilePaths ?? []
      self?.pendingOpenFilePaths.removeAll()
      result(paths)
    }

    // Register C2PA native channel (iOS 16+ only).
    // Requires c2pa-swift added via Xcode > Add Package Dependencies.
    if #available(iOS 16, *) {
      guard let registrar = engineBridge.pluginRegistry.registrar(
        forPlugin: "C2paNativeHandler"
      ) else {
        assertionFailure("Unable to create the C2PA Flutter plugin registrar")
        return
      }
      C2paNativeHandler.register(with: registrar.messenger())
    }

    if !pendingOpenFilePaths.isEmpty {
      DispatchQueue.main.async { [weak self] in
        self?.mediaOpenChannel?.invokeMethod("mediaFilesOpened", arguments: nil)
      }
    }
  }

  private func queueOpenedMediaFiles(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    for path in paths where !pendingOpenFilePaths.contains(path) {
      pendingOpenFilePaths.append(path)
    }
    mediaOpenChannel?.invokeMethod("mediaFilesOpened", arguments: nil)
  }
}
