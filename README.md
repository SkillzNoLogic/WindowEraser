# WindowEraser

<img src="WindowEraser/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg" width="64" alt="WindowEraser icon: an eraser rubbing out a window">

**Erase apps from Mission Control and bring them back with a secret trackpad gesture.**

WindowEraser is a small macOS menu bar app. Pick any app and tie it to a trackpad gesture.
Do the gesture and the app appears; do it again and it vanishes. While it's erased, its
windows don't show up on screen or in Mission Control (F3 or the three-finger swipe up).
If something tries to bring it back (a Dock click, Cmd-Tab, relaunching it), WindowEraser
hides it again instantly.

## Features

- **Gesture configurator.** Choose an open app, choose a gesture, click **Tie**.
- **One gesture per app.** The gesture toggles the app: it shows it (launching it if it
  isn't running), and doing it again hides it.
- **Nine gestures to pick from.** Double tap, triple tap, or press-and-hold with 3, 4 or 5 fingers.
  None of them clash with clicking, scrolling, or the built-in swipes and pinches.
- **Stays erased.** Hidden apps are re-hidden the moment anything else unhides or activates them.
- **Remembers everything.** Tied apps and gestures survive quitting the app, restarting
  WindowEraser, and rebooting. When you open a saved app it ties itself to its gesture again
  automatically.
- **Hide without a gesture.** Erase any running app with one click, or add an app from
  Applications before it's even open.
- **Lives in the menu bar.** No Dock icon and no windows, just the eraser icon in the menu bar.
- **Options:** re-hide shown apps when you switch away, keep saved apps open when you launch
  them, and launch at login.

## Requirements

- macOS 27 or later (Apple silicon)
- A built-in trackpad or Magic Trackpad (needed for gestures; everything else works without one)

## Install

Download one of these from the [latest release](../../releases/latest):

| File | How to install |
|---|---|
| `WindowEraser-x.y.z.dmg` | Open it and drag **WindowEraser** onto **Applications**. |
| `WindowEraser-x.y.z.pkg` | Double-click and follow the installer. It installs to `/Applications`. |
| `WindowEraser-x.y.z.zip` | Unzip and move **WindowEraser.app** to `/Applications`. |

### First launch

The release is not notarized by Apple, so macOS blocks it the first time you open it. To allow it:

1. Open **WindowEraser** once and dismiss the warning.
2. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to WindowEraser.

Or remove the download quarantine flag from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/WindowEraser.app
```

## How to use

1. Click the eraser icon in the menu bar.
2. In **Gesture configurator**, pick an open app and a gesture, then click **Tie**.
3. Do the gesture anywhere to hide the app. Do it again to bring it back.

Under **Tied & hidden apps** you can change an app's gesture, show or hide it with the eye
button, or untie it with **✕**, which also stops hiding it. **Running apps** lets you hide an
app with no gesture; get it back from the menu bar.

Tip: if **Look up & data detectors** is set to *Tap with three fingers* in Trackpad settings,
use 4- or 5-finger gestures to avoid triggering it.

## Limitations

- **Whole apps, not single windows.** macOS has no public API for removing one window of another
  app from Mission Control, so WindowEraser hides the entire app.
- **Dock and Cmd-Tab.** A hidden app that's running still has a Dock icon and a Cmd-Tab entry.
  Choosing it there just gets it hidden again. macOS doesn't let one app remove another app's Dock icon.
- **Private API.** Gesture detection reads raw trackpad touches through Apple's private
  `MultitouchSupport` framework (the same approach tools like BetterTouchTool use). That's why
  the app isn't sandboxed or on the App Store, and a future macOS update could break gestures.

## Privacy

WindowEraser makes no network connections. Your tied apps and gestures are stored locally in
the app's preferences.

## Build from source

Requires Xcode 27.

```sh
git clone https://github.com/SkillzNoLogic/WindowEraser.git
cd WindowEraser
open WindowEraser.xcodeproj   # then press ⌘R
```

Or from the command line:

```sh
xcodebuild -project WindowEraser.xcodeproj -scheme WindowEraser -configuration Release build
```
