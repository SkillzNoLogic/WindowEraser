import Foundation

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
nonisolated final class GestureMonitor: @unchecked Sendable {
    static let shared = GestureMonitor()

    typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32

    private typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

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
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
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
    }

    var isAvailable: Bool { createList != nil && register != nil && startDevice != nil }

    func setHandler(_ handler: @escaping @Sendable (TrackpadGesture) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Only gestures in this set are reported. This also decides whether a double tap
    /// must wait to see if a triple tap follows.
    func setEnabledGestures(_ gestures: Set<TrackpadGesture>) {
        lock.withLock {
            enabled = gestures
            sessions.removeAll()
        }
    }

    func start() {
        guard isAvailable, devices.isEmpty, let createList, let register, let startDevice,
              let raw = createList() else { return }
        let list = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        deviceList = list
        for i in 0..<CFArrayGetCount(list) {
            guard let value = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: value)
            register(device, callback)
            _ = startDevice(device, 0)
            devices.append(device)
        }
    }

    func stop() {
        for device in devices {
            unregister?(device, callback)
            _ = stopDevice?(device)
        }
        devices.removeAll()
        deviceList = nil
        lock.withLock { sessions.removeAll() }
    }

    /// Touch devices stop reporting after sleep and new trackpads aren't picked up
    /// automatically, so this is called on wake and periodically.
    func restart() {
        stop()
        start()
    }

    func restartIfDevicesChanged() {
        guard let createList, let raw = createList() else { return }
        let count = CFArrayGetCount(Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue())
        if count != devices.count { restart() }
    }

    // Called on the framework's touch thread for every frame.
    private func process(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        var fire: TrackpadGesture?
        var scheduleDouble: (key: Int, sequence: Int, gesture: TrackpadGesture)?

        lock.lock()
        let key = Int(bitPattern: device)
        var s = sessions[key] ?? Session()

        var down: [MTTouch] = []
        if let touches, count > 0 {
            let buffer = touches.assumingMemoryBound(to: MTTouch.self)
            for i in 0..<count where (3...5).contains(buffer[i].state) {
                down.append(buffer[i])
            }
        }

        if !down.isEmpty {
            if !s.active {
                s.active = true
                s.startTime = timestamp
                s.fullTime = timestamp
                s.maxFingers = 0
                s.origins = [:]
                s.drift = 0
                s.holdFired = false
            }
            if down.count > s.maxFingers {
                s.maxFingers = down.count
                s.fullTime = timestamp
            }
            for touch in down {
                let p = touch.normalized.position
                if let o = s.origins[touch.identifier] {
                    s.drift = max(s.drift, hypotf(p.x - o.x, p.y - o.y))
                } else {
                    s.origins[touch.identifier] = p
                }
            }
            if !s.holdFired, down.count == s.maxFingers, s.drift <= maxDrift,
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
