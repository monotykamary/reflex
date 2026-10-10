import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

// Keeps the Mac from sleeping while your agents work (after localterm's
// keep-awake). Three modes:
//
//   off      macOS sleeps as usual
//   agents   awake while any agent is working, and a minute after the last
//            one stops (so the gap between turns does not let it doze)
//   always   awake while Reflex runs
//
// On battery at or below the floor it lets go, whatever the mode: a Mac left
// unplugged stops keeping itself awake before it dies. Native power
// assertions, not a `caffeinate` child: nothing to orphan, and Activity
// Monitor's Energy tab shows it under Reflex.

@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    enum Mode: String, CaseIterable { case off, agents, always }

    /// Whether the Mac is being kept awake right now, and why (for Settings).
    @Published private(set) var holding = false
    @Published private(set) var reason = ""
    /// On battery at or below the floor: held off.
    @Published private(set) var batteryLow = false

    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0
    private var lastWorking: Date?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    static let grace: TimeInterval = 60

    func start() {
        let s = Settings.shared
        Publishers.MergeMany(
            s.$awakeMode.map { _ in () }.eraseToAnyPublisher(),
            s.$awakeDisplay.map { _ in () }.eraseToAnyPublisher(),
            s.$awakeBattery.map { _ in () }.eraseToAnyPublisher(),
            Store.shared.$state.map { $0.agents.filter { $0.status == "working" }.count }.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in DispatchQueue.main.async { self?.update() } }
        .store(in: &bag)
        // The grace period and the battery need a clock of their own.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    func update() {
        let s = Settings.shared
        let working = Store.shared.state.agents.filter { $0.status == "working" }.count
        if working > 0 { lastWorking = Date() }
        let floor = s.awakeBattery
        batteryLow = floor > 0 && KeepAwake.battery().map { !$0.charging && $0.percent <= floor } ?? false

        var want = false
        var why = ""
        switch Mode(rawValue: s.awakeMode) ?? .agents {
        case .off:
            break
        case .always:
            want = true
            why = "Always on"
        case .agents:
            if working > 0 {
                want = true
                why = working == 1 ? "1 agent is working" : "\(working) agents are working"
            } else if let t = lastWorking, Date().timeIntervalSince(t) < KeepAwake.grace {
                want = true
                why = "An agent just finished — letting go in a minute"
            }
        }
        if want && batteryLow {
            want = false
            why = "On battery at \(KeepAwake.battery()?.percent ?? floor)% — letting the Mac sleep"
        }
        apply(want, display: s.awakeDisplay)
        if reason != why { reason = why }
    }

    private func apply(_ want: Bool, display keepDisplay: Bool) {
        hold(&system, want, kIOPMAssertionTypePreventUserIdleSystemSleep)
        hold(&display, want && keepDisplay, kIOPMAssertionTypePreventUserIdleDisplaySleep)
        if holding != want { holding = want }
    }

    private func hold(_ id: inout IOPMAssertionID, _ on: Bool, _ type: String) {
        if on && id == 0 {
            var new: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Reflex: keeping the Mac awake for your agents" as CFString, &new)
            if r == kIOReturnSuccess { id = new }
        } else if !on && id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    /// The internal battery, if there is one: its charge, and whether it is
    /// on AC power.
    nonisolated static func battery() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cur * 100 / max, ac)
        }
        return nil
    }
}
