import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

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
  }
}
