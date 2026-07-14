import AppKit

@main
@MainActor
enum DropperMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        installMainMenu(app)
        registerBundledFonts()
        app.run()
    }

    /// Makes the bundled annotation font (Caveat, OFL) available to
    /// CoreText before any markup window resolves it.
    private static func registerBundledFonts() {
        guard let url = Bundle.module.url(forResource: "Caveat",
                                          withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Accessory apps get no menu bar UI, but the main menu still routes key
    /// equivalents — without an Edit menu, ⌘V/⌘C/⌘X/⌘A do nothing in any of
    /// our windows (wizard, settings). Install the standard set.
    private static func installMainMenu(_ app: NSApplication) {
        let main = NSMenu()

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close Window",
                       action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        app.mainMenu = main
    }
}
