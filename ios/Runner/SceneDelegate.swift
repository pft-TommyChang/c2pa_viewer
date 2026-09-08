import Flutter
import UIKit

final class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(
      scene,
      willConnectTo: session,
      options: connectionOptions
    )

    for context in connectionOptions.urlContexts {
      handleIncomingURL(context.url)
    }
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    // Do not forward this callback to FlutterSceneDelegate. On the current
    // Flutter engine it can recreate the implicit Flutter root while the app
    // is being foregrounded, which loses the media handoff state. The app
    // delegate still receives the URL below and forwards it to the live Dart
    // page through the media channel.
    for context in URLContexts {
      handleIncomingURL(context.url)
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    (UIApplication.shared.delegate as? AppDelegate)?.handleSceneDidBecomeActive()
  }

  private func handleIncomingURL(_ url: URL) {
    guard url.scheme == "c2pa-viewer" else { return }
    (UIApplication.shared.delegate as? AppDelegate)?.handleIncomingURL(url)
  }
}
