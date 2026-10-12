import Foundation
import IOKit.ps
import notify

/// When the big first pass (backfill) may run: with the Mac cool (thermal state nominal or fair), not in Low Power
/// Mode, and on AC power if indexing on battery is off (it's on by default). A few new files always index right away;
/// they take seconds.
///
/// Event-driven: power-source, thermal and Low Power Mode changes call `onChange`; nothing polls.
final class PowerPolicy {
    private var indexOnBattery: Bool
    private let onChange: (String?) -> Void
    nonisolated(unsafe) private var powerToken = NOTIFY_TOKEN_INVALID   // main thread, and deinit
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private(set) var blocker: String?

    /// `onChange` gets why the backfill has to wait, or nil when it may run.
    init(indexOnBattery: Bool, onChange: @escaping (String?) -> Void) {
        self.indexOnBattery = indexOnBattery
        self.onChange = onChange
        blocker = Self.backfillBlocker(indexOnBattery: indexOnBattery)

        // AC/battery switches only: IOPSNotificationCreateRunLoopSource also fires on every battery percentage change.
        notify_register_dispatch(kIOPSNotifyPowerSource, &powerToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            })
        }
    }

    deinit {
        notify_cancel(powerToken)
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The "index on battery too" setting changed.
    func setIndexOnBattery(_ on: Bool) {
        indexOnBattery = on
        reevaluate()
    }

    private func reevaluate() {
        let now = Self.backfillBlocker(indexOnBattery: indexOnBattery)
        guard now != blocker else { return }
        blocker = now
        log("power: backfill \(now.map { "waits (\($0))" } ?? "may run")")
        onChange(now)
    }

    nonisolated static func backfillBlocker(indexOnBattery: Bool) -> String? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return "Low Power Mode" }
        switch info.thermalState {
        case .serious, .critical: return "Mac is warm"
        default: break
        }
        if !indexOnBattery, !onACPower() { return "on battery" }
        return nil
    }

    nonisolated static func onACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }   // no power-source info: a desktop Mac
        return type == kIOPMACPowerKey
    }
}
