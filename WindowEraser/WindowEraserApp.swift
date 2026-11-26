import AppKit
import SwiftUI

@main struct WindowEraserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // No Dock icon or windows (LSUIElement): the menu bar item is the only UI.
    var body: some Scene {
        MenuBarExtra("WindowEraser", image: "MenuBarIcon") {
            ControllerView(stash: appDelegate.stash, gestureAvailable: GestureMonitor.shared.isAvailable)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let stash = StashManager()
    private static weak var current: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        // The handler goes in first. The trackpads are only opened once the saved
        // gestures are loaded in `stash.start()`, and only if there are any.
        GestureMonitor.shared.setHandler { gesture in
            Task { @MainActor in AppDelegate.current?.stash.handle(gesture) }
        }
        stash.start()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            GestureMonitor.shared.systemWillSleep()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            GestureMonitor.shared.systemDidWake()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GestureMonitor.shared.shutDown()
    }
}
