import OSLog

/// Central logger namespace. Subsystem matches the bundle identifier so that
/// `log stream --predicate 'subsystem == "com.mrcookie.Murmur"'` shows everything.
enum Log {
    private static let subsystem = "com.mrcookie.Murmur"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let output = Logger(subsystem: subsystem, category: "output")
    static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
}
