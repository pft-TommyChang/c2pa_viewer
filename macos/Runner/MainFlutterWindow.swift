import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let startupChannelName = "c2pa_viewer/startup"
  private let startupBackgroundColor = NSColor(
    srgbRed: 0xF3 / 255.0,
    green: 0xEF / 255.0,
    blue: 0xE7 / 255.0,
    alpha: 1
  )
  private weak var startupView: NSView?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.backgroundColor = startupBackgroundColor
    flutterViewController.backgroundColor = startupBackgroundColor
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Perfect C2PA"
    self.contentMinSize = NSSize(width: 800, height: 600)

    installStartupView(over: flutterViewController.view)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let startupChannel = FlutterMethodChannel(
      name: startupChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    startupChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "dismiss" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.dismissStartupView()
      result(nil)
    }

    super.awakeFromNib()
  }

  private func installStartupView(over flutterView: NSView) {
    let startupView = NSView(frame: flutterView.bounds)
    startupView.autoresizingMask = [.width, .height]
    startupView.wantsLayer = true
    startupView.layer?.backgroundColor = startupBackgroundColor.cgColor

    let iconView = NSImageView()
    iconView.image = NSApplication.shared.applicationIconImage
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false

    let appNameLabel = NSTextField(labelWithString: "Perfect C2PA")
    appNameLabel.font = .systemFont(ofSize: 36, weight: .semibold)
    appNameLabel.textColor = NSColor(
      srgbRed: 0x17 / 255.0,
      green: 0x1A / 255.0,
      blue: 0x21 / 255.0,
      alpha: 1
    )
    appNameLabel.alignment = .center

    let contentStack = NSStackView(views: [iconView, appNameLabel])
    contentStack.orientation = .horizontal
    contentStack.alignment = .centerY
    contentStack.spacing = 20
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    startupView.addSubview(contentStack)

    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 96),
      iconView.heightAnchor.constraint(equalToConstant: 96),
      contentStack.centerXAnchor.constraint(equalTo: startupView.centerXAnchor),
      contentStack.centerYAnchor.constraint(equalTo: startupView.centerYAnchor),
    ])

    flutterView.addSubview(startupView)
    self.startupView = startupView
  }

  private func dismissStartupView() {
    guard let startupView else {
      return
    }
    self.startupView = nil

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      startupView.animator().alphaValue = 0
    } completionHandler: {
      startupView.removeFromSuperview()
    }
  }
}
