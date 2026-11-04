import Foundation

/// BLINK_TIMING=1 prints milliseconds since process start at launch milestones (for
/// tuning launch speed). Costs nothing when unset.
enum LaunchTiming {
    static let enabled = ProcessInfo.processInfo.environment["BLINK_TIMING"] != nil

    static func mark(_ label: String) {
        guard enabled else { return }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        let ms = Double(now.tv_sec - start.tv_sec) * 1000 + Double(now.tv_usec - start.tv_usec) / 1000
        FileHandle.standardError.write("[\(String(format: "%6.1f", ms)) ms] \(label)\n".data(using: .utf8)!)
    }
}
