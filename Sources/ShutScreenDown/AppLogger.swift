import Foundation

/// 写日志到 ~/Library/Logs/ShutScreenDown.log，超过 1MB 自动截断重来。
/// 出问题时对照日志即可知道 App 每一步做了什么、为什么。
final class AppLogger {
    static let shared = AppLogger()

    private let url: URL
    private let lock = NSLock()
    private let formatter: DateFormatter

    private init() {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("ShutScreenDown.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
