import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Lazy because a drop on a non-running Dropper delivers open(urls) before
    // applicationDidFinishLaunching.
    private lazy var controller = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        _ = controller  // create the status item
        // Launch is silent for configured users — just the menu bar icon.
        // A fresh install (no credentials) gets the setup wizard instead:
        // that's the whole first-run experience.
        if !controller.hasCredentials {
            controller.openOnboarding()
        }
    }

    /// Files opened via Finder ("Open With" / drag onto the app icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        controller.handleDrop(urls: urls)
    }
}
