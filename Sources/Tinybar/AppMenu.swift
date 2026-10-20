import AppKit

/// Accessory apps have no default menu. Native commands still need one for keyboard equivalents.
@MainActor
enum AppMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Tinybar")
        appMenu.addItem(withTitle: "Quit Tinybar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        // A nil target sends Close through the responder chain to the key window.
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        return menu
    }
}
