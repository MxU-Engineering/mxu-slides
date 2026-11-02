import Darwin

public enum ProcessFootprint {
    public static func megabytes() -> (now: Double, peak: Double)? {
        var usage = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard status == 0 else { return nil }
        return (Double(usage.ri_phys_footprint) / 1_048_576,
                Double(usage.ri_lifetime_max_phys_footprint) / 1_048_576)
    }
}
