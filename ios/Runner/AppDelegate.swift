import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let mediaOpenChannelName = "c2pa_viewer/media_open"
  private var mediaOpenChannel: FlutterMethodChannel?
  private var pendingOpenFilePaths: [String] = []
  private var pendingHandoffGeneration = 0
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
    handleSceneDidBecomeActive()
  }

  // With a scene-based application, the scene lifecycle can be delivered
  // without applicationDidBecomeActive. Keep the shared-media handoff on
  // both paths so returning to the app always drains the extension inbox.
  func handleSceneDidBecomeActive() {
    consumeSharedMediaInboxWithRetry()
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    handleIncomingURL(url)
    return url.scheme == "c2pa-viewer"
  }

  func handleIncomingURL(_ url: URL) {
    guard url.scheme == "c2pa-viewer" else { return }
    consumeSharedMediaInboxWithRetry()
  }

  private func consumeSharedMediaInboxWithRetry(retriesRemaining: Int = 8) {
    let paths = sharedMediaQueue.consumePendingFiles()
    queueOpenedMediaFiles(paths)

    // The share extension and the containing app are activated concurrently.
    // Retry briefly in case iOS activates the app before the extension has
    // finished writing the shared file into the App Group container.
    guard retriesRemaining > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.consumeSharedMediaInboxWithRetry(
        retriesRemaining: retriesRemaining - 1
      )
    }
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
      guard let self else {
        result([])
        return
      }
      let paths = self.pendingOpenFilePaths
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

    // Cover both cold launch and the case where the app was already running
    // and the URL event arrived before the Flutter handler was installed.
    consumeSharedMediaInboxWithRetry()
  }

  private func queueOpenedMediaFiles(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    // A new share replaces the previous handoff. Keep this batch available to
    // a second Flutter root during cold-start; Dart deduplicates repeated
    // reads from the same root.
    pendingOpenFilePaths = paths
    pendingHandoffGeneration += 1
    let generation = pendingHandoffGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self, self.pendingHandoffGeneration == generation else { return }
      self.pendingOpenFilePaths.removeAll()
    }
    // Include the paths in the event itself. Flutter can then accept the
    // handoff even when the app is being foregrounded and a follow-up channel
    // call would race with engine startup.
    mediaOpenChannel?.invokeMethod("mediaFilesOpened", arguments: paths)
  }
}
