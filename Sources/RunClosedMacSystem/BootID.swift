import Foundation

public enum BootID {
    /// The kernel boot session UUID. Monotonic deadlines are only valid within one
    /// boot; this is how the Core detects and drops stale leases.
    public static func current() -> String {
        var size = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) != 0 || size == 0 {
            return ""
        }
        var buf = [UInt8](repeating: 0, count: size)
        if sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) != 0 {
            return ""
        }
        // Drop the trailing NUL before decoding.
        if let nul = buf.firstIndex(of: 0) { buf = Array(buf[..<nul]) }
        return String(decoding: buf, as: UTF8.self)
    }
}
