import Foundation
import IOKit

// Raw trackpad touch data from Apple's private MultitouchSupport framework.
// This is the same source tools like BetterTouchTool use: it sees every finger on
// every trackpad, even while macOS is consuming the touches for its own gestures.
// The layout mirrors the C struct the framework hands to the contact callback.

nonisolated struct MTPoint {
    var x: Float
    var y: Float
}

nonisolated struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

nonisolated struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var zero2: (Int32, Int32)
    var density: Float
}

/// Recognizes the `TrackpadGesture`s that are currently assigned, on any connected trackpad.
///
/// To stay out of the way it only listens when it has to:
/// - only to trackpads (a Magic Mouse is also a multitouch device, and is skipped)
/// - only while at least one gesture is assigned
/// - not while the Mac sleeps
/// Plugging trackpads in or out is picked up from IOKit notifications, not by polling.
nonisolated final class GestureMonitor: @unchecked Sendable {
    static let shared = GestureMonitor()

    typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32

    private typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias DeviceIDFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32

    // Tuning.
    private let maxTapDuration = 0.45   // seconds from first finger down to last finger up
    private let maxTapGap = 0.5         // seconds allowed between taps in a sequence
    private let holdDuration = 0.7      // seconds all fingers must rest for a hold
    private let maxDrift: Float = 0.06  // normalized distance a finger may move and still count

    private struct Session {
        var active = false
        var startTime = 0.0
        var fullTime = 0.0       // when the current finger count was reached
        var maxFingers = 0
        var origins: [Int32: MTPoint] = [:]
        var drift: Float = 0
        var holdFired = false
        // Tap sequence, which spans several touch sessions.
        var tapFingers = 0
        var tapCount = 0
        var lastTapEnd = -1.0
        var sequence = 0

        mutating func resetTaps() {
            tapCount = 0
            lastTapEnd = -1
            sequence += 1
        }
    }

    private let lock = NSLock()
    private var sessions: [Int: Session] = [:]
    private var enabled: Set<TrackpadGesture> = []
    private var handler: (@Sendable (TrackpadGesture) -> Void)?

    private var createList: CreateListFn?
    private var register: RegisterFn?
    private var unregister: RegisterFn?
    private var startDevice: StartFn?
    private var stopDevice: StopFn?
    private var deviceID: DeviceIDFn?
    private var deviceList: CFArray?
    // Device handling below happens on the main thread only.
    private var devices: [UnsafeMutableRawPointer] = []
    private var isSleeping = false
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var pendingRefresh: DispatchWorkItem?
    private let callback: ContactCallback

    private init() {
        callback = { device, touches, count, timestamp, _ in
            GestureMonitor.shared.process(device: device, touches: touches, count: Int(count), timestamp: timestamp)
            return 0
        }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib = dlopen(path, RTLD_NOW) else { return }
        func load<T>(_ name: String, as: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: T.self) }
        }
        createList = load("MTDeviceCreateList", as: CreateListFn.self)
        register = load("MTRegisterContactFrameCallback", as: RegisterFn.self)
        unregister = load("MTUnregisterContactFrameCallback", as: RegisterFn.self)
        startDevice = load("MTDeviceStart", as: StartFn.self)
        stopDevice = load("MTDeviceStop", as: StopFn.self)
        deviceID = load("MTDeviceGetDeviceID", as: DeviceIDFn.self)
    }

    var isAvailable: Bool { createList != nil && register != nil && startDevice != nil }

    func setHandler(_ handler: @escaping @Sendable (TrackpadGesture) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Only gestures in this set are reported. This also decides whether a double tap
    /// must wait to see if a triple tap follows. With no gestures assigned, the trackpads
    /// aren't listened to at all. Call on the main thread.
    func setEnabledGestures(_ gestures: Set<TrackpadGesture>) {
        lock.withLock {
            enabled = gestures
            sessions.removeAll()
        }
        updateListening()
    }

    /// Starts or stops listening to match what's needed. Call on the main thread.
    func updateListening() {
        let wanted = !isSleeping && !lock.withLock { enabled.isEmpty }
        if wanted, devices.isEmpty {
            start()
        } else if !wanted, !devices.isEmpty {
            stop()
        }
    }

    func systemWillSleep() {
        isSleeping = true
        stop()
    }

    /// Touch devices stop reporting across sleep, so they're reopened on wake.
    func systemDidWake() {
        isSleeping = false
        stop()
        updateListening()
    }

    func shutDown() {
        stop()
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    private func start() {
        guard isAvailable, devices.isEmpty, let createList, let register, let startDevice,
              let raw = createList() else { return }
        let list = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        deviceList = list
        let mice = Self.mouseMultitouchIDs()
        for i in 0..<CFArrayGetCount(list) {
            guard let value = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: value)
            var id: UInt64 = 0
            if let deviceID, deviceID(device, &id) == 0, mice.contains(id) { continue }
            register(device, callback)
            _ = startDevice(device, 0)
            devices.append(device)
        }
        watchForDeviceChanges()
    }

    private func stop() {
        for device in devices {
            unregister?(device, callback)
            _ = stopDevice?(device)
        }
        devices.removeAll()
        deviceList = nil
        lock.withLock { sessions.removeAll() }
    }

    /// Multitouch IDs of mice (Magic Mouse). Each multitouch device's IOKit parent is its
    /// HID event driver, which says whether it's a mouse or a trackpad.
    private static func mouseMultitouchIDs() -> Set<UInt64> {
        var ids = Set<UInt64>()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else {
            return ids
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                if IOObjectConformsTo(parent, "AppleMultitouchMouseHIDEventDriver") != 0,
                   let value = IORegistryEntryCreateCFProperty(service, "Multitouch ID" as CFString, kCFAllocatorDefault, 0)?
                       .takeRetainedValue() as? NSNumber {
                    ids.insert(value.uint64Value)
                }
                IOObjectRelease(parent)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return ids
    }

    /// Asks IOKit to report multitouch devices being added or removed, instead of polling.
    private func watchForDeviceChanges() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let changed: IOServiceMatchingCallback = { _, iterator in
            GestureMonitor.drain(iterator)
            GestureMonitor.shared.devicesChanged()
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
                                         changed, nil, &addedIterator)
        Self.drain(addedIterator)  // Arms the notification; current devices are already open.
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"),
                                         changed, nil, &removedIterator)
        Self.drain(removedIterator)
    }

    private static func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    /// Runs on the main run loop. Waits briefly so a device that's still connecting is ready.
    private func devicesChanged() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [self] in
            // Reopen from scratch. This also catches a trackpad plugged in while nothing was
            // open (say, only a Magic Mouse was connected).
            stop()
            updateListening()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // Called on the framework's touch thread for every frame.
    private func process(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        var fire: TrackpadGesture?
        var scheduleDouble: (key: Int, sequence: Int, gesture: TrackpadGesture)?

        lock.lock()
        guard !enabled.isEmpty else {
            lock.unlock()
            return
        }
        let key = Int(bitPattern: device)
        var s = sessions[key] ?? Session()

        // Fingers actually touching (states 3...5); others are hovering or lifting off.
        let buffer = touches?.assumingMemoryBound(to: MTTouch.self)
        var downCount = 0
        if let buffer {
            for i in 0..<count where (3...5).contains(buffer[i].state) { downCount += 1 }
        }

        if let buffer, downCount > 0 {
            if !s.active {
                s.active = true
                s.startTime = timestamp
                s.fullTime = timestamp
                s.maxFingers = 0
                s.origins = [:]
                s.drift = 0
                s.holdFired = false
            }
            if downCount > s.maxFingers {
                s.maxFingers = downCount
                s.fullTime = timestamp
            }
            for i in 0..<count where (3...5).contains(buffer[i].state) {
                let touch = buffer[i]
                let p = touch.normalized.position
                if let o = s.origins[touch.identifier] {
                    s.drift = max(s.drift, hypotf(p.x - o.x, p.y - o.y))
                } else {
                    s.origins[touch.identifier] = p
                }
            }
            if !s.holdFired, downCount == s.maxFingers, s.drift <= maxDrift,
               timestamp - s.fullTime >= holdDuration,
               let hold = TrackpadGesture.hold(fingers: s.maxFingers), enabled.contains(hold) {
                s.holdFired = true
                s.resetTaps()
                fire = hold
            }
        } else if s.active {
            s.active = false
            let isTap = (3...5).contains(s.maxFingers)
                && !s.holdFired
                && timestamp - s.startTime <= maxTapDuration
                && s.drift <= maxDrift
            if isTap {
                let continues = s.lastTapEnd >= 0
                    && s.startTime - s.lastTapEnd <= maxTapGap
                    && s.tapFingers == s.maxFingers
                s.tapCount = continues ? s.tapCount + 1 : 1
                s.tapFingers = s.maxFingers
                s.lastTapEnd = timestamp
                s.sequence += 1

                let double = TrackpadGesture.tap(fingers: s.maxFingers, taps: 2)
                let triple = TrackpadGesture.tap(fingers: s.maxFingers, taps: 3)
                let tripleEnabled = triple.map(enabled.contains) ?? false

                if s.tapCount >= 3 {
                    if tripleEnabled { fire = triple }
                    s.resetTaps()
                } else if s.tapCount == 2, let double, enabled.contains(double) {
                    if tripleEnabled {
                        // Wait to see whether a third tap turns this into a triple tap.
                        scheduleDouble = (key, s.sequence, double)
                    } else {
                        fire = double
                        s.resetTaps()
                    }
                }
            } else {
                s.resetTaps()
            }
        }

        sessions[key] = s
        let handler = self.handler
        lock.unlock()

        if let fire { handler?(fire) }
        if let pending = scheduleDouble {
            DispatchQueue.global().asyncAfter(deadline: .now() + maxTapGap) { [self] in
                resolvePendingDouble(key: pending.key, sequence: pending.sequence, gesture: pending.gesture)
            }
        }
    }

    private func resolvePendingDouble(key: Int, sequence: Int, gesture: TrackpadGesture) {
        lock.lock()
        guard var s = sessions[key], s.sequence == sequence, s.tapCount == 2, !s.active else {
            lock.unlock()
            return
        }
        s.resetTaps()
        sessions[key] = s
        let handler = self.handler
        lock.unlock()
        handler?(gesture)
    }
}
