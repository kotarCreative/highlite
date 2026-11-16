import AppKit

@MainActor
enum AppMenu {
    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Highlite")
        applicationMenu.addItem(command(
            "Quit Highlite",
            action: #selector(NSApplication.terminate(_:)),
            key: "q"
        ))
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(command("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(command("Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(command("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(command("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(command("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(command("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }

    private static func command(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // Let AppKit route editing to the focused field and preserve secure-field restrictions.
        item.target = nil
        return item
    }
}
