import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar controller: hide apps, give each one a gesture, show/hide them.
struct ControllerView: View {
    @Bindable var stash: StashManager
    let gestureAvailable: Bool

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var configApp: String?
    @State private var configGesture: TrackpadGesture?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    configurator
                    Divider()
                    hiddenSection
                    runningSection
                }
                .padding(14)
            }
            .frame(height: 460)
            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear {
            stash.refresh()
            launchAtLogin = LoginItem.isEnabled
            if configGesture == nil { configGesture = firstFreeGesture }
        }
    }

    // MARK: - Gesture configurator

    private var configurator: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Gesture configurator")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("App").foregroundStyle(.secondary)
                    Picker("App", selection: $configApp) {
                        Text("Choose an open app…").tag(String?.none)
                        Divider()
                        ForEach(stash.openApps, id: \.processIdentifier) { app in
                            Label {
                                Text(app.localizedName ?? "App")
                            } icon: {
                                Image(nsImage: menuIcon(app.icon))
                            }
                            .tag(StashManager.key(for: app))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Gesture").foregroundStyle(.secondary)
                    Picker("Gesture", selection: $configGesture) {
                        Text("Choose a gesture…").tag(TrackpadGesture?.none)
                        Divider()
                        ForEach(TrackpadGesture.allCases) { gesture in
                            Text(label(for: gesture, excluding: configApp)).tag(TrackpadGesture?.some(gesture))
                        }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Tie", action: tieGesture)
                    .buttonStyle(.borderedProminent)
                    .disabled(configApp == nil || configGesture == nil)
            }
        }
    }

    private func tieGesture() {
        guard let id = configApp, let gesture = configGesture else { return }
        stash.bind(gesture, to: id)
        configApp = nil
        configGesture = firstFreeGesture
    }

    private var firstFreeGesture: TrackpadGesture? {
        let used = Set(stash.gestures.values)
        return TrackpadGesture.allCases.first { !used.contains($0) }
    }

    private func menuIcon(_ icon: NSImage?) -> NSImage {
        let image = (icon ?? NSWorkspace.shared.icon(for: .application)).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WindowEraser").font(.headline)
            if !stash.accessibilityTrusted {
                HStack {
                    Label("Fullscreen apps need Accessibility access", systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow") { stash.requestAccessibility() }
                        .controlSize(.small)
                        .help("Lets WindowEraser take apps out of fullscreen before hiding them, so their Space leaves Mission Control")
                }
            }
            if !gestureAvailable {
                Label("Trackpad gestures are unavailable on this Mac.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var hiddenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Tied & hidden apps")
                Spacer()
                Button("Add App…", action: chooseApps)
                    .controlSize(.small)
            }
            let entries = stash.hiddenEntries
            if entries.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                AppRow(icon: entry.icon, name: entry.name, detail: detail(for: entry),
                       detailColor: entry.isStuckFullscreen ? .orange : .secondary) {
                    if entry.isStuckFullscreen {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.fullscreenFix, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("This app won't leave fullscreen, so its Space stays in Mission Control. Click to copy a Steam launch option that fixes this for most games (Properties → Launch Options), then relaunch the game. Or play in windowed mode.")
                    }
                    Button {
                        stash.toggle(entry.id)
                    } label: {
                        Image(systemName: entry.isShowing ? "eye.slash" : "eye")
                    }
                    .help(entry.isShowing ? "Hide now" : "Show now")
                    Button {
                        stash.release(entry.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Stop hiding this app")
                }
                gesturePicker(for: entry)
                    .padding(.leading, 38)
            }
        }
    }

    private func gesturePicker(for entry: HiddenEntry) -> some View {
        let selection = Binding<TrackpadGesture?>(
            get: { stash.gestures[entry.id] },
            set: { stash.assign($0, to: entry.id) }
        )
        return Picker("Gesture", selection: selection) {
            Text("No gesture").tag(TrackpadGesture?.none)
            Divider()
            ForEach(TrackpadGesture.allCases) { gesture in
                Text(label(for: gesture, excluding: entry.id)).tag(TrackpadGesture?.some(gesture))
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Running apps")
            ForEach(stash.visibleApps, id: \.processIdentifier) { app in
                AppRow(icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
                       name: app.localizedName ?? "App",
                       detail: nil) {
                    Button("Hide") {
                        if let id = StashManager.key(for: app) { stash.hide(id) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep saved apps open and tied when I open them", isOn: $stash.keepTiedAppsOpenOnLaunch)
                .help("Off: a saved app is hidden the moment it opens")
            Toggle("Hide shown apps again when I switch away", isOn: $stash.rehideOnSwitch)
            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LoginItem.isEnabled else { return }
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .help("Hidden apps stay hidden but can be opened normally again")
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
    }

    /// Steam launch option that makes SDL games go fullscreen without their own Space.
    private static let fullscreenFix = "SDL_VIDEO_MAC_FULLSCREEN_SPACES=0 %command%"

    private func detail(for entry: HiddenEntry) -> String {
        if entry.isShowing { return "Showing" }
        if entry.isStuckFullscreen { return "Fullscreen: still in Mission Control" }
        return entry.isRunning ? "Hidden" : "Hidden · not running"
    }

    private func label(for gesture: TrackpadGesture, excluding id: String?) -> String {
        guard let owner = stash.gestures.first(where: { $0.value == gesture && $0.key != id })?.key else {
            return gesture.title
        }
        return "\(gesture.title) (used by \(stash.appName(for: owner)))"
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Hide"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { stash.addApp(at: url) }
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct AppRow<Actions: View>: View {
    let icon: NSImage
    let name: String
    let detail: String?
    var detailColor: Color = .secondary
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(detailColor)
                }
            }
            Spacer()
            actions
        }
    }
}
