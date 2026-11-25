import AppKit
import ApplicationServices

/// A fullscreen app gets its own Space, and Mission Control keeps showing that Space even
/// after the app is hidden. These helpers find such apps and take them in and out of
/// fullscreen. Finding them reads the Space list from the private SkyLight framework
/// (read-only). Switching fullscreen uses the Accessibility API, like pressing the
/// green window button, and needs Accessibility permission.
enum Fullscreen {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> UnsafeMutableRawPointer?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let mainConnection: ConnectionFn? = symbol("SLSMainConnectionID")
    private static let copySpaces: CopySpacesFn? = symbol("SLSCopyManagedDisplaySpaces")
    private static let fullscreenSpaceType = 4

    private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// PIDs of apps that currently own a fullscreen Space, or nil if the Space list can't be read.
    static func spaceOwnerPIDs() -> Set<pid_t>? {
        guard let mainConnection, let copySpaces, let raw = copySpaces(mainConnection()) else { return nil }
        let displays = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as? [[String: Any]] ?? []
        var pids = Set<pid_t>()
        for display in displays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] where space["type"] as? Int == fullscreenSpaceType {
                let tiles = (space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]] ?? []
                for tile in tiles {
                    if let pid = tile["pid"] as? Int { pids.insert(pid_t(pid)) }
                }
            }
        }
        return pids
    }

    // MARK: - Accessibility

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends you to Accessibility settings.
    static func promptForTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The app's windows. Some apps (many games) report no window list over Accessibility
    /// but do expose their main/focused window, so those are used as a fallback.
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var result: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement] {
            result = list
        }
        if result.isEmpty {
            for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                var window: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, attribute as CFString, &window) == .success,
                      let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { continue }
                let element = window as! AXUIElement
                if !result.contains(where: { CFEqual($0, element) }) { result.append(element) }
            }
        }
        return result
    }

    static func isFullscreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    static func fullscreenWindows(of pid: pid_t) -> [AXUIElement] {
        windows(of: pid).filter { isFullscreen($0) }
    }

    static func setFullscreen(_ window: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
