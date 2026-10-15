import Foundation

/// The app reads the screen through the Accessibility API, which Apple doesn't allow inside
/// the App Sandbox, so the app can't be sandboxed. It still gives up the network: at launch
/// it applies a sandbox profile to itself that allows everything except IP networking, after
/// which the kernel refuses its TCP/UDP connections. It can't be undone for the life of the
/// process. (`sandbox_init` is deprecated but still ships; see the README for how to check.)
///
/// Note: macOS 27 kills a process that applies the built-in named profile ("no-network",
/// `SANDBOX_NAMED`) at this point; a profile string works. Checked 2026-10-15.
public enum NoNetwork {
    @_silgen_name("sandbox_init")
    private static func sandbox_init(
        _ profile: UnsafePointer<CChar>, _ flags: UInt64, _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> Int32

    @_silgen_name("sandbox_free_error")
    private static func sandbox_free_error(_ errorbuf: UnsafeMutablePointer<CChar>?)

    /// Everything allowed except IP networking. Local (Unix-domain) sockets and Mach
    /// services, which AppKit, Accessibility and Apple Events use, are untouched.
    static let profile = """
        (version 1)
        (allow default)
        (deny network-outbound (remote ip))
        (deny network-inbound (local ip))
        (deny network-bind (local ip))
        """

    /// `defaults write rs.appea.appears applyNoNetworkProfile -bool NO` turns it off, in case
    /// it ever gets in the way of the Accessibility API while testing.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "applyNoNetworkProfile") as? Bool ?? true
    }

    public private(set) nonisolated(unsafe) static var isApplied = false

    /// Applies the profile. Returns an error message if it couldn't.
    @discardableResult
    public static func apply() -> String? {
        guard isEnabled else { return "turned off with the applyNoNetworkProfile default" }
        var error: UnsafeMutablePointer<CChar>?
        let result = profile.withCString { sandbox_init($0, 0, &error) }
        if result == 0 {
            isApplied = true
            return nil
        }
        let message = error.map { String(cString: $0) } ?? "sandbox_init failed"
        sandbox_free_error(error)
        return message
    }

    /// Tries to open a TCP connection to a public address, to prove it fails. For the
    /// developer check in Settings and the CLI; it sends nothing.
    public static func probe() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(443).bigEndian
        address.sin_addr.s_addr = inet_addr("1.1.1.1")
        // Non-blocking, so the check never waits on a real network.
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        // EINPROGRESS means the kernel allowed it to start; EPERM means the profile blocked it.
        return result == 0 || errno == EINPROGRESS
    }
}
