import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel(settings: Settings())
        self.model = model
        statusItem = StatusItemController(model: model)
        model.start()
    }
}

HistoryImport.runChildIfRequested()
MainActor.assumeIsolated { PopoverSnapshot.runIfRequested() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
