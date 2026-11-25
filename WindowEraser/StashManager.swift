import AppKit
import Observation
import UniformTypeIdentifiers

struct HiddenEntry: Identifiable {
    let id: String  // bundle identifier
    let name: String
    let icon: NSImage
    let isRunning: Bool
    let isShowing: Bool
    let gesture: TrackpadGesture?
}

/// Keeps chosen apps hidden. A hidden app's windows don't appear in Mission Control
/// (F3 / three-finger swipe up) or on screen. If anything else unhides or activates
/// one (Dock click, Cmd-Tab, relaunch), it is hidden again right away. Only `toggle`
/// (the app's gesture or the menu bar controller) can show it.
@Observable
final class StashManager {
    private(set) var hiddenIDs: [String]
    private(set) var gestures: [String: TrackpadGesture]
    private(set) var revealedIDs: Set<String> = []
    private(set) var runningApps: [NSRunningApplication] = []

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

    private enum Keys {
        static let hidden = "hiddenBundleIDs"
        static let gestures = "appGestures"
        static let rehide = "rehideOnSwitch"
        static let keepOpen = "keepTiedAppsOpenOnLaunch"
    }

    init() {
        let defaults = UserDefaults.standard
        hiddenIDs = defaults.stringArray(forKey: Keys.hidden) ?? []
        let stored = defaults.dictionary(forKey: Keys.gestures) as? [String: String] ?? [:]
        gestures = stored.compactMapValues(TrackpadGesture.init(rawValue:))
        rehideOnSwitch = defaults.object(forKey: Keys.rehide) as? Bool ?? true
        keepTiedAppsOpenOnLaunch = defaults.object(forKey: Keys.keepOpen) as? Bool ?? true
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
                let bundleID = app?.bundleIdentifier
                MainActor.assumeIsolated { self?.handle(name, pid: pid, bundleID: bundleID) }
            }
            observers.append(token)
        }
        // Safety net for anything that slips past the notifications.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.enforceAll() }
        }
        pushGestures()
        refresh()
        // Apps already running when WindowEraser starts keep their saved hidden state.
        knownPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        enforceAll()
    }

    func refresh() {
        runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && $0.bundleIdentifier != nil
        }
    }

    // MARK: - Lists for the UI

    var hiddenEntries: [HiddenEntry] {
        hiddenIDs.map { id in
            let running = runningApps.first { $0.bundleIdentifier == id }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = running?.localizedName
                ?? url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? id
            let icon = running?.icon
                ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .application)
            return HiddenEntry(id: id, name: name, icon: icon, isRunning: running != nil,
                               isShowing: revealedIDs.contains(id), gesture: gestures[id])
        }
    }

    var visibleApps: [NSRunningApplication] {
        var seen = Set<String>()
        return runningApps.filter { app in
            guard let id = app.bundleIdentifier, !hiddenIDs.contains(id) else { return false }
            return seen.insert(id).inserted
        }
    }

    /// Every open app (one entry per bundle ID), for the gesture configurator.
    var openApps: [NSRunningApplication] {
        var seen = Set<String>()
        return runningApps
            .filter { seen.insert($0.bundleIdentifier ?? "").inserted }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    func appName(for id: String) -> String {
        hiddenEntries.first { $0.id == id }?.name ?? id
    }

    // MARK: - Actions

    func hide(bundleID id: String) {
        if !hiddenIDs.contains(id) {
            hiddenIDs.append(id)
            saveHidden()
        }
        conceal(id)
    }

    /// Stop hiding an app for good.
    func release(_ id: String) {
        hiddenIDs.removeAll { $0 == id }
        revealedIDs.remove(id)
        gestures[id] = nil
        saveHidden()
        saveGestures()
        apps(withID: id).forEach { $0.unhide() }
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

    private func reveal(_ id: String) {
        revealedIDs.insert(id)
        apps(withID: id).forEach { $0.unhide() }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    private func conceal(_ id: String) {
        revealedIDs.remove(id)
        apps(withID: id).forEach { $0.hide() }
    }

    // MARK: - Enforcement

    private func handle(_ name: Notification.Name, pid: pid_t?, bundleID: String?) {
        refresh()
        guard let pid, pid != ownPID else { return }

        // The process is already gone here, so this case can't look the app up by PID.
        if name == NSWorkspace.didTerminateApplicationNotification {
            knownPIDs.remove(pid)
            if let bundleID, apps(withID: bundleID).isEmpty { revealedIDs.remove(bundleID) }
            return
        }

        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if name == NSWorkspace.didActivateApplicationNotification, rehideOnSwitch {
            noteLaunchIfNew(app)
            for id in revealedIDs where id != app.bundleIdentifier { conceal(id) }
        }
        enforce(app)
    }

    /// A saved app with a gesture that has just been opened re-ties itself: it's marked as
    /// shown, so it stays open and its gesture hides it.
    private func noteLaunchIfNew(_ app: NSRunningApplication) {
        guard knownPIDs.insert(app.processIdentifier).inserted else { return }
        guard keepTiedAppsOpenOnLaunch, let id = app.bundleIdentifier,
              hiddenIDs.contains(id), gestures[id] != nil else { return }
        revealedIDs.insert(id)
    }

    private func enforce(_ app: NSRunningApplication) {
        noteLaunchIfNew(app)
        guard let id = app.bundleIdentifier, hiddenIDs.contains(id), !revealedIDs.contains(id), !app.isHidden else { return }
        app.hide()
    }

    private func enforceAll() {
        for app in NSWorkspace.shared.runningApplications { enforce(app) }
    }

    private func apps(withID id: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
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
