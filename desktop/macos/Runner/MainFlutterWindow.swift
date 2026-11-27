import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var windowFrame = self.frame
    windowFrame.size.width = max(windowFrame.size.width, 1180)
    windowFrame.size.height = max(windowFrame.size.height, 760)
    self.title = "TreeScan"
    self.contentMinSize = NSSize(width: 920, height: 560)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
