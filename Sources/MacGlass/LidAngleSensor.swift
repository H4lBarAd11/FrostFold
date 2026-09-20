import Foundation
import IOKit.hid

/// Reads the continuous lid-angle sensor exposed by MacBooks as an Apple HID
/// sensor device (`las`, usage page 0x20 / usage 0x8A).
///
/// Two feature reports carry the angle. Report 7 is a little-endian UInt32 in
/// hundredths of a degree; report 1 is a little-endian UInt16 in whole degrees.
/// We prefer 7 and fall back to 1 on machines that only implement the latter.
final class LidAngleSensor {

    struct Sample {
        let angle: Double       // smoothed, degrees
        let rawAngle: Double    // unsmoothed, degrees
        let isMoving: Bool
    }

    enum Report {
        case hiRes  // id 7, UInt32 hundredths of a degree
        case loRes  // id 1, UInt16 whole degrees

        var id: Int { self == .hiRes ? 7 : 1 }
        var length: Int { self == .hiRes ? 5 : 3 }
    }

    private let device: IOHIDDevice
    private let report: Report
    /// The manager owns the open handle on the device. Let it go out of scope
    /// and the device closes, after which every `GetReport` quietly fails.
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "io.github.macglass.sensor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var smoothed: Double = 0
    private var lastAccepted: Double = 0
    private var lastSampleTime = CFAbsoluteTimeGetCurrent()
    private var lastMotionTime: CFAbsoluteTime = 0
    private var started = false

    /// Called on the main queue for every accepted sample.
    var onSample: ((Sample) -> Void)?

    deinit {
        timer?.cancel()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Seconds of sub-threshold movement before we consider the lid settled.
    private let settleDelay: CFTimeInterval = 0.35

    // MARK: - Discovery

    init?() {
        guard let (mgr, dev, rep) = Self.locate() else { return nil }
        manager = mgr
        device = dev
        report = rep
        if let a = Self.read(dev, rep) {
            smoothed = a
            lastAccepted = a
        }
    }

    private static func locate() -> (IOHIDManager, IOHIDDevice, Report)? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: 0x20,   // Sensor
            kIOHIDPrimaryUsageKey: 0x8A,       // Orientation: compound
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else { return nil }

        for device in devices {
            // Prefer the high-resolution report where the machine offers it.
            if read(device, .hiRes) != nil { return (manager, device, .hiRes) }
            if read(device, .loRes) != nil { return (manager, device, .loRes) }
        }
        return nil
    }

    private static func read(_ device: IOHIDDevice, _ report: Report) -> Double? {
        var buffer = [UInt8](repeating: 0, count: report.length)
        var length = buffer.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature,
                                          CFIndex(report.id), &buffer, &length)
        guard result == kIOReturnSuccess, length == report.length, Int(buffer[0]) == report.id
        else { return nil }

        switch report {
        case .hiRes:
            let raw = UInt32(buffer[1]) | UInt32(buffer[2]) << 8
                    | UInt32(buffer[3]) << 16 | UInt32(buffer[4]) << 24
            let degrees = Double(raw) / 100.0
            return (0...180).contains(degrees) ? degrees : nil
        case .loRes:
            let raw = UInt16(buffer[1]) | UInt16(buffer[2]) << 8
            let degrees = Double(raw)
            return (0...180).contains(degrees) ? degrees : nil
        }
    }

    var currentAngle: Double? { Self.read(device, report) }

    // MARK: - Polling

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.schedule(hz: Double(Settings.shared.stationaryFPS.rawValue))
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.started = false
        }
    }

    /// Re-arms the poll timer at a new rate. Must run on `queue`.
    private func schedule(hz: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / hz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        currentHz = hz
    }

    private var currentHz: Double = 30

    private func tick() {
        guard let raw = Self.read(device, report) else { return }
        let settings = Settings.shared
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(1.0 / 240.0, min(0.25, now - lastSampleTime))
        lastSampleTime = now

        // Deadband: ignore jitter below the threshold so the pane holds still
        // when the lid is parked part-way open.
        if abs(raw - lastAccepted) >= settings.movementThreshold {
            lastAccepted = raw
            lastMotionTime = now
        }

        let moving = (now - lastMotionTime) < settleDelay

        // Exponential smoothing; the time constant shortens as responsiveness rises.
        let tau = 0.18 - 0.172 * settings.responsiveness   // 0.18s (languid) ... 0.008s (immediate)
        let alpha = 1.0 - exp(-dt / max(0.004, tau))
        smoothed += (lastAccepted - smoothed) * alpha

        // While moving, sample at 120 Hz; otherwise drop back to the idle rate.
        let wanted = moving ? 120.0 : Double(settings.stationaryFPS.rawValue)
        if abs(wanted - currentHz) > 0.5 { schedule(hz: wanted) }

        let sample = Sample(angle: smoothed, rawAngle: raw, isMoving: moving)
        DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
    }
}
