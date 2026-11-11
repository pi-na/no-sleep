import Foundation
import IOKit.ps

struct BatteryState: Equatable {
    var percentage: Int
    var onBattery: Bool

    /// Internal battery state, or nil on Macs without one.
    static func current() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let max = description["Max Capacity"] as? Int, max > 0
            else { continue }
            let state = description["Power Source State"] as? String
            return BatteryState(percentage: current * 100 / max, onBattery: state == "Battery Power")
        }
        return nil
    }
}
