# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

WindowEraser (formerly JustHide) is a macOS agent app (`LSUIElement`: no Dock icon) whose only UI is a menu bar item (`MenuBarExtra`, window style). You hide apps there and can give each hidden app its own trackpad gesture. That gesture toggles the app: it shows it (launching it if needed), and doing it again hides it. Hidden apps stay hidden, so their windows are absent from Mission Control (F3 / three-finger swipe up). No tests. Published at github.com/SkillzNoLogic/WindowEraser (public); `README.md` is the user-facing docs.

## Build

`xcodebuild` needs full Xcode. The active developer dir on this machine is Command Line Tools, so prefix with `DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project WindowEraser.xcodeproj -scheme WindowEraser -destination 'platform=macOS' build
```

## Release

Releases are ad-hoc signed (not with the Apple Development cert, which would embed the developer's email) and not notarized. The target is macOS 27, so builds are arm64 only. Packaging used for v1.0.0, with build output in a scratch dir `$S`:

```sh
xcodebuild -project WindowEraser.xcodeproj -scheme WindowEraser -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath $S/rel \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
ditto -c -k --sequesterRsrc --keepParent WindowEraser.app WindowEraser-$V.zip
# dmg: folder with the app + an /Applications symlink -> hdiutil create -format UDZO
# pkg: pkgroot/Applications/WindowEraser.app -> pkgbuild --analyze, set BundleIsRelocatable NO,
#      pkgbuild --root pkgroot --component-plist ... --install-location /
gh release create v$V *.dmg *.pkg *.zip SHA256SUMS.txt
```

Bump `MARKETING_VERSION` in the project before a release.

## Architecture

- `WindowEraserApp.swift`: `@main` App with a single `MenuBarExtra` hosting `ControllerView`. `AppDelegate` (via `@NSApplicationDelegateAdaptor`) owns the `StashManager`, routes recognized gestures to `stash.handle(_:)`, and restarts the touch monitor on wake and when trackpads appear or disappear.
- `TrackpadGesture.swift`: the fixed set of assignable gestures (3/4/5-finger double tap, triple tap, and hold). Each gesture belongs to at most one app.
- `GestureMonitor.swift`: loads the **private** `MultitouchSupport.framework` with `dlopen`/`dlsym` and registers a C contact-frame callback per trackpad. `MTTouch` must match the framework's C struct layout byte-for-byte (96-byte stride). The callback runs on a framework thread, so the class is `nonisolated` + `@unchecked Sendable` with an `NSLock`. It only reports gestures in the enabled set. A double tap is delayed by the tap gap when the matching triple tap is also enabled.
- `StashManager.swift`: hiding engine and model. Apps are identified by an **app key**: the bundle ID, or the bundle/executable path when there is none (`StashManager.key(for:)`, e.g. Hades); never use `bundleIdentifier` directly. It hides apps with `NSRunningApplication.hide()`, persists hidden app keys (still under the `hiddenBundleIDs` defaults key), last-known app paths (`appPaths`, preferred over Launch Services when launching), and gesture assignments in `UserDefaults`, and re-hides on any `NSWorkspace` launch/activate/unhide notification plus a 1s timer. Apps in `revealedIDs` are exempt. With `rehideOnSwitch` on, activating any other app conceals them.
- `Fullscreen.swift`: a fullscreen app owns its own Space, and Mission Control keeps showing that Space even after `hide()`. This file finds Space owners through private SkyLight `SLSCopyManagedDisplaySpaces` (read-only, type 4 = fullscreen) and toggles `AXFullScreen` (needs Accessibility; falls back to `AXMainWindow`/`AXFocusedWindow` when `AXWindows` is empty, as with many games). `StashManager.hideApp` exits fullscreen, waits for 2 clean readings, then hides, and restores fullscreen on reveal. SDL games (e.g. Celeste) ignore the toggle. After 2 refusals the app is hidden directly and the UI shows a warning with the Steam launch option `SDL_VIDEO_MAC_FULLSCREEN_SPACES=0 %command%`.
- `ControllerView.swift`: the SwiftUI controller (gesture configurator that ties an open app to a gesture via `StashManager.bind`, tied/hidden apps with gesture pickers, running apps, "Add App…" via `NSOpenPanel`, settings). `LoginItem.swift`: launch at login via `SMAppService`.

## Constraints

- App Sandbox is **off** on purpose (private frameworks + controlling other apps). Keep it off.
- Accessibility permission is tied to the code signature, and debug builds are ad-hoc signed, so it may need re-granting after rebuilds (remove and re-add WindowEraser in Privacy & Security → Accessibility).
- Windows games run through CrossOver/Wine are not supported: they live inside Wine processes, not their own apps.
- Hiding is per-app, not per-window: there is no public API to remove a single window of another app from Mission Control. Hidden apps still appear in the Dock and Cmd-Tab (selecting them just gets re-hidden). Single taps, two-finger gestures and swipes are deliberately not offered because they clash with clicking, scrolling and system gestures.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with Swift 5 language mode: everything is `@MainActor` unless marked `nonisolated`. Notification/timer closures hop back with `MainActor.assumeIsolated`.
- `MemberImportVisibility` is enabled: import the defining module explicitly (e.g. `UniformTypeIdentifiers` for `UTType.application`).
- `WindowEraser/` is a file-system-synchronized group, so new files are picked up automatically. Info.plist is generated; add keys as `INFOPLIST_KEY_*` build settings.
- The bundle identifier is still the template placeholder and deliberately ends in `.justhide` (not the product name), because saved hidden apps and gestures live in that `UserDefaults` domain. Set a real one before signing and distributing, but expect to lose saved settings when you do. Launch at login needs a properly signed build.
