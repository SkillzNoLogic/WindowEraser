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
    private var deviceTimer: Timer?
    private static weak var current: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        stash.start()

        let monitor = GestureMonitor.shared
        monitor.setHandler { gesture in
            Task { @MainActor in AppDelegate.current?.stash.handle(gesture) }
        }
        monitor.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            GestureMonitor.shared.restart()
        }
        // Pick up trackpads that are connected or disconnected while running.
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            GestureMonitor.shared.restartIfDevicesChanged()
        }
    }
}
