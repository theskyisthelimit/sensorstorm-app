import Foundation

/// The single time base of the whole app.
///
/// Every sample — motion, GPS, audio level, video frame — is stored as seconds on the
/// *host clock* (`mach_absolute_time` converted to seconds). This is the same base that
/// `CMLogItem.timestamp` uses and the same one `CMClockGetHostTimeClock()` drives, so
/// motion samples and video presentation timestamps line up without any conversion or
/// drift. Wall-clock sources (`CLLocation.timestamp`, `Date`) are mapped in through
/// ``wallToHostOffset``.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Seconds since boot, on the host clock.
    public static var now: Double {
        seconds(fromTicks: mach_absolute_time())
    }

    public static func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Add this to a `Date`'s `timeIntervalSince1970` to get host seconds.
    ///
    /// Sampled fresh on every call; both clocks are driven by the same oscillator, so the
    /// offset only moves when the wall clock is stepped (NTP, timezone-independent).
    public static var wallToHostOffset: Double {
        now - Date().timeIntervalSince1970
    }

    /// Converts a wall-clock date into host seconds using an offset captured at session start.
    public static func hostSeconds(for date: Date, offset: Double) -> Double {
        date.timeIntervalSince1970 + offset
    }
}
