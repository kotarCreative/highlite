import AppKit
import HighliteMenuBarCore

@main
enum HighliteMenuBarMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegateHolder.shared = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private enum AppDelegateHolder {
    static var shared: AppDelegate?
}
