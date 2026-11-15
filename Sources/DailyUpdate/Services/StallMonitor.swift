import Foundation

/// Opt-in diagnostics for "the window is frozen": with `DAILY_UPDATE_STALL_LOG=1` a background timer pings the main
/// thread every 100 ms and prints to stderr every time the answer takes more than 300 ms, with the phase markers
/// the app set around its heavy steps. Off by default: nothing runs and nothing is printed.
enum StallMonitor {
    static let environmentKey = "DAILY_UPDATE_STALL_LOG"
    static let enabled = ProcessInfo.processInfo.environment[environmentKey] == "1"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastPong = Date()
    nonisolated(unsafe) private static var phase = "startup"
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    private static let queue = DispatchQueue(label: "dailyupdate.stallmonitor", qos: .utility)

    static func start() {
        guard enabled, timer == nil else { return }
        lastPong = Date()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.1, repeating: 0.1)
        source.setEventHandler {
            let ping = Date()
            DispatchQueue.main.async { lock.lock(); lastPong = Date(); lock.unlock() }
            queue.asyncAfter(deadline: .now() + 0.05) {
                lock.lock(); let pong = lastPong; let current = phase; lock.unlock()
                let waited = Date().timeIntervalSince(pong)
                if pong < ping, waited > 0.3 {
                    FileHandle.standardError.write(Data(String(format: "STALL main thread unresponsive for %.0f ms (phase: %@)\n", waited * 1000, current).utf8))
                }
            }
        }
        source.resume()
        timer = source
    }

    /// Marks the start of a step. Cheap when the monitor is off.
    static func mark(_ name: String) {
        guard enabled else { return }
        lock.lock(); phase = name; lock.unlock()
        FileHandle.standardError.write(Data(String(format: "PHASE %.3f %@\n", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10_000), name).utf8))
    }
}
