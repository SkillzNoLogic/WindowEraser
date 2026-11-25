import AppKit
import ApplicationServices
import Observation
import UniformTypeIdentifiers

struct HiddenEntry: Identifiable {
    let id: String  // app key: bundle ID, or the app's path if it has none
    let name: String
    let icon: NSImage
    let isRunning: Bool
    let isShowing: Bool
    /// Hidden, but it refused to leave fullscreen, so its Space is still in Mission Control.
    let isStuckFullscreen: Bool
    let gesture: TrackpadGesture?
}

/// Keeps chosen apps hidden. A hidden app's windows don't appear in Mission Control
/// (F3 / three-finger swipe up) or on screen. If anything else unhides or activates
/// one (Dock click, Cmd-Tab, relaunch), it is hidden again right away. Only `toggle`
/// (the app's gesture or the menu bar controller) can show it.
///
/// Apps are identified by an "app key": the bundle ID, or the path to the app when it
/// has no bundle ID (some games, e.g. Hades). Existing saved bundle IDs are valid keys.
@Observable
final class StashManager {
    private(set) var hiddenIDs: [String]
    private(set) var gestures: [String: TrackpadGesture]
    private(set) var revealedIDs: Set<String> = []
    private(set) var runningApps: [NSRunningApplication] = []
    /// Apps that currently own a fullscreen Space.
    private(set) var fullscreenPIDs: Set<pid_t> = []
    private(set) var accessibilityTrusted = Fullscreen.isTrusted

    /// Put a shown app back into hiding as soon as you switch to another app.
    var rehideOnSwitch: Bool {
        didSet { UserDefaults.standard.set(rehideOnSwitch, forKey: Keys.rehide) }
    }

    /// When a saved app that has a gesture is opened, it stays on screen, already tied to
    /// its gesture (do the gesture to hide it). When off, it's hidden the moment it opens.
    var keepTiedAppsOpenOnLaunch: Bool {
        didSet { UserDefaults.standard.set(keepTiedAppsOpenOnLaunch, forKey: Keys.keepOpen) }
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Processes already seen, so a new PID means the app was just opened.
    @ObservationIgnored private var knownPIDs: Set<pid_t> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Last known location of each saved app. Used to launch apps that Launch Services
    /// can't find (or finds the wrong copy of) by bundle ID, such as Steam games.
    @ObservationIgnored private var appPaths: [String: String]
    /// Apps currently being taken out of fullscreen before they're hidden.
    @ObservationIgnored private var exitingFullscreen: Set<pid_t> = []
    /// Windows taken out of fullscreen before hiding, put back when the app is shown.
    @ObservationIgnored private var fullscreenToRestore: [String: [AXUIElement]] = [:]
    /// How often each app ignored a request to leave fullscreen (many games do). After two
    /// refusals it isn't asked again this session. One miss can just be bad timing, e.g.
    /// hiding an app mid-way through its enter-fullscreen animation.
    @ObservationIgnored private var fullscreenRefusals: [String: Int] = [:]
    @ObservationIgnored private var askedForAccessibility = false

    private enum Keys {
        static let hidden = "hiddenBundleIDs"
        static let gestures = "appGestures"
        static let paths = "appPaths"
        static let rehide = "rehideOnSwitch"
        static let keepOpen = "keepTiedAppsOpenOnLaunch"
    }

    init() {
        let defaults = UserDefaults.standard
        hiddenIDs = defaults.stringArray(forKey: Keys.hidden) ?? []
        let stored = defaults.dictionary(forKey: Keys.gestures) as? [String: String] ?? [:]
        gestures = stored.compactMapValues(TrackpadGesture.init(rawValue:))
        appPaths = defaults.dictionary(forKey: Keys.paths) as? [String: String] ?? [:]
        rehideOnSwitch = defaults.object(forKey: Keys.rehide) as? Bool ?? true
        keepTiedAppsOpenOnLaunch = defaults.object(forKey: Keys.keepOpen) as? Bool ?? true
    }

    /// How an app is identified: its bundle ID, or its path when it has none.
    nonisolated static func key(for app: NSRunningApplication) -> String? {
        app.bundleIdentifier ?? app.bundleURL?.path ?? app.executableURL?.path
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                let key = app.flatMap(StashManager.key(for:))
                MainActor.assumeIsolated { self?.handle(name, pid: pid, key: key) }
            }
            observers.append(token)
        }
        // Safety net for anything that slips past the notifications.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFullscreen()
                self?.enforceAll()
            }
        }
        pushGestures()
        refresh()
        // Apps already running when WindowEraser starts keep their saved hidden state.
        knownPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        enforceAll()
    }

    func refresh() {
        runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && Self.key(for: $0) != nil
        }
        rememberPaths()
        refreshFullscreen()
    }

    private func refreshFullscreen() {
        let pids = Fullscreen.spaceOwnerPIDs() ?? []
        if pids != fullscreenPIDs { fullscreenPIDs = pids }
        let trusted = Fullscreen.isTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }

    private func rememberPaths() {
        var changed = false
        for app in runningApps {
            guard let key = Self.key(for: app), hiddenIDs.contains(key), !key.hasPrefix("/"),
                  let path = app.bundleURL?.path, appPaths[key] != path else { continue }
            appPaths[key] = path
            changed = true
        }
        if changed { UserDefaults.standard.set(appPaths, forKey: Keys.paths) }
    }

    // MARK: - Lists for the UI

    var hiddenEntries: [HiddenEntry] {
        hiddenIDs.map { id in
            let running = runningApps.filter { Self.key(for: $0) == id }
            let url = appURL(for: id)
            let name = running.first?.localizedName ?? url.map { Self.displayName(for: $0) } ?? id
            let icon = running.first?.icon
                ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .application)
            let isShowing = revealedIDs.contains(id)
            let stuck = !isShowing && running.contains {
                fullscreenPIDs.contains($0.processIdentifier) && !exitingFullscreen.contains($0.processIdentifier)
            }
            return HiddenEntry(id: id, name: name, icon: icon, isRunning: !running.isEmpty,
                               isShowing: isShowing, isStuckFullscreen: stuck, gesture: gestures[id])
        }
    }

    var visibleApps: [NSRunningApplication] {
        var seen = Set<String>()
        return runningApps.filter { app in
            guard let id = Self.key(for: app), !hiddenIDs.contains(id) else { return false }
            return seen.insert(id).inserted
        }
    }

    /// Every open app (one entry per app key), for the gesture configurator.
    var openApps: [NSRunningApplication] {
        var seen = Set<String>()
        return runningApps
            .filter { seen.insert(Self.key(for: $0) ?? "").inserted }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    func appName(for id: String) -> String {
        hiddenEntries.first { $0.id == id }?.name ?? id
    }

    // MARK: - Actions

    func hide(_ id: String) {
        if !hiddenIDs.contains(id) {
            hiddenIDs.append(id)
            saveHidden()
            rememberPaths()
        }
        conceal(id)
    }

    /// Hide an app chosen in Finder, which may not be running yet.
    func addApp(at url: URL) {
        let key = Bundle(url: url)?.bundleIdentifier ?? url.path
        if !key.hasPrefix("/") {
            appPaths[key] = url.path
            UserDefaults.standard.set(appPaths, forKey: Keys.paths)
        }
        hide(key)
    }

    /// Stop hiding an app for good.
    func release(_ id: String) {
        hiddenIDs.removeAll { $0 == id }
        revealedIDs.remove(id)
        gestures[id] = nil
        saveHidden()
        saveGestures()
        apps(withID: id).forEach { $0.unhide() }
        restoreFullscreenIfNeeded(id)
    }

    /// Give a hidden app a gesture. A gesture belongs to one app at a time, so it
    /// is taken away from whichever app had it before.
    func assign(_ gesture: TrackpadGesture?, to id: String) {
        if let gesture {
            for (other, g) in gestures where g == gesture { gestures[other] = nil }
        }
        gestures[id] = gesture
        saveGestures()
    }

    /// Tie a gesture to an app from the configurator. The app becomes managed. If it's
    /// on screen right now it stays there (marked as shown), and the gesture hides it.
    func bind(_ gesture: TrackpadGesture, to id: String) {
        assign(gesture, to: id)
        guard !hiddenIDs.contains(id) else { return }
        hiddenIDs.append(id)
        saveHidden()
        rememberPaths()
        if apps(withID: id).contains(where: { !$0.isHidden }) {
            revealedIDs.insert(id)
        }
    }

    /// What an app's gesture does: show it if hidden (launching it if needed), hide it if shown.
    func toggle(_ id: String) {
        if revealedIDs.contains(id) {
            conceal(id)
        } else {
            reveal(id)
        }
    }

    func handle(_ gesture: TrackpadGesture) {
        guard let id = gestures.first(where: { $0.value == gesture })?.key else { return }
        toggle(id)
    }

    func requestAccessibility() {
        Fullscreen.promptForTrust()
        Fullscreen.openAccessibilitySettings()
    }

    private func reveal(_ id: String) {
        revealedIDs.insert(id)
        let running = apps(withID: id)
        running.forEach { $0.unhide() }
        if let url = appURL(for: id) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        } else {
            running.first?.activate()
        }
        restoreFullscreenIfNeeded(id)
    }

    private func conceal(_ id: String) {
        revealedIDs.remove(id)
        apps(withID: id).forEach(hideApp)
    }

    // MARK: - Hiding, with fullscreen handling

    /// Hides an app. A fullscreen app is first taken out of fullscreen, otherwise its
    /// Space would stay in Mission Control. The windows go back to fullscreen when it's shown.
    private func hideApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !exitingFullscreen.contains(pid), let key = Self.key(for: app) else { return }

        let ownsSpace = Fullscreen.spaceOwnerPIDs()?.contains(pid)
            ?? (Fullscreen.isTrusted && !Fullscreen.fullscreenWindows(of: pid).isEmpty)
        guard ownsSpace, fullscreenRefusals[key, default: 0] < 2 else {
            app.hide()
            return
        }
        guard Fullscreen.isTrusted else {
            if !askedForAccessibility {
                askedForAccessibility = true
                Fullscreen.promptForTrust()
            }
            app.hide()
            refreshFullscreen()
            return
        }
        let windows = Fullscreen.fullscreenWindows(of: pid)
        guard !windows.isEmpty else {
            app.hide()
            return
        }

        exitingFullscreen.insert(pid)
        windows.forEach { Fullscreen.setFullscreen($0, false) }
        Task { [weak self] in
            // Wait for the exit animation. Require two clean readings in a row, because the
            // Space list can briefly read empty mid-transition.
            var left = false
            var cleanReadings = 0
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(100))
                let stillFullscreen = Fullscreen.spaceOwnerPIDs()?.contains(pid) ?? false
                    || windows.contains { Fullscreen.isFullscreen($0) }
                cleanReadings = stillFullscreen ? 0 : cleanReadings + 1
                if cleanReadings >= 2 {
                    left = true
                    break
                }
            }
            if left { try? await Task.sleep(for: .milliseconds(200)) }
            self?.finishHiding(pid: pid, key: key, windows: windows, leftFullscreen: left)
        }
    }

    private func finishHiding(pid: pid_t, key: String, windows: [AXUIElement], leftFullscreen: Bool) {
        exitingFullscreen.remove(pid)
        if leftFullscreen {
            fullscreenToRestore[key] = windows
            fullscreenRefusals[key] = nil
        } else {
            fullscreenRefusals[key, default: 0] += 1
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // Shown again (or released) while it was leaving fullscreen.
        guard hiddenIDs.contains(key), !revealedIDs.contains(key) else {
            restoreFullscreenIfNeeded(key)
            return
        }
        app.hide()
        refreshFullscreen()
    }

    private func restoreFullscreenIfNeeded(_ id: String) {
        guard let windows = fullscreenToRestore.removeValue(forKey: id), !windows.isEmpty else { return }
        Task {
            // Give the app time to unhide and come forward before entering fullscreen.
            try? await Task.sleep(for: .milliseconds(700))
            windows.forEach { Fullscreen.setFullscreen($0, true) }
        }
    }

    // MARK: - Enforcement

    private func handle(_ name: Notification.Name, pid: pid_t?, key: String?) {
        refresh()
        guard let pid, pid != ownPID else { return }

        // The process is already gone here, so this case can't look the app up by PID.
        if name == NSWorkspace.didTerminateApplicationNotification {
            knownPIDs.remove(pid)
            exitingFullscreen.remove(pid)
            if let key, apps(withID: key).isEmpty {
                revealedIDs.remove(key)
                fullscreenToRestore[key] = nil
            }
            return
        }

        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if name == NSWorkspace.didActivateApplicationNotification, rehideOnSwitch {
            noteLaunchIfNew(app)
            for id in revealedIDs where id != key { conceal(id) }
        }
        enforce(app)
    }

    /// A saved app with a gesture that has just been opened re-ties itself: it's marked as
    /// shown, so it stays open and its gesture hides it.
    private func noteLaunchIfNew(_ app: NSRunningApplication) {
        guard knownPIDs.insert(app.processIdentifier).inserted else { return }
        guard keepTiedAppsOpenOnLaunch, let id = Self.key(for: app),
              hiddenIDs.contains(id), gestures[id] != nil else { return }
        revealedIDs.insert(id)
    }

    private func enforce(_ app: NSRunningApplication) {
        noteLaunchIfNew(app)
        guard let id = Self.key(for: app), hiddenIDs.contains(id), !revealedIDs.contains(id), !app.isHidden else { return }
        hideApp(app)
    }

    private func enforceAll() {
        for app in NSWorkspace.shared.runningApplications { enforce(app) }
    }

    // MARK: - Helpers

    private func apps(withID id: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { Self.key(for: $0) == id }
    }

    /// Where to launch a saved app from. The remembered path wins over a Launch Services
    /// lookup, because some apps share a bundle ID with a helper app (e.g. Brotato).
    private func appURL(for id: String) -> URL? {
        if id.hasPrefix("/") {
            return id.hasSuffix(".app") ? URL(fileURLWithPath: id) : nil
        }
        if let path = appPaths[id], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    private static func displayName(for url: URL) -> String {
        let info = Bundle(url: url)?.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func saveHidden() {
        UserDefaults.standard.set(hiddenIDs, forKey: Keys.hidden)
    }

    private func saveGestures() {
        UserDefaults.standard.set(gestures.mapValues(\.rawValue), forKey: Keys.gestures)
        pushGestures()
    }

    private func pushGestures() {
        GestureMonitor.shared.setEnabledGestures(Set(gestures.values))
    }
}
