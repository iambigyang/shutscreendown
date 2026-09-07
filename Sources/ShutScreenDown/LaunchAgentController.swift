import Foundation

/// 开机自启（launchd LaunchAgent）管理。
///
/// 设计要点：
/// - 开机自启 = plist 存在于 ~/Library/LaunchAgents/（RunAtLoad + KeepAlive）。
///   KeepAlive 让 App 崩溃后由 launchd 自动拉起（自愈）。
/// - 勾选「开机自启」只写 plist，不做 bootstrap：App 当前已在运行，
///   plist 下次登录生效即可，避免同时出现两个实例。
/// - 菜单「退出」时：若检测到自己是被 launchd 拉起的（bootstrapped），
///   先 bootout 再退出，否则 KeepAlive 会把刚退出的 App 又拉起来。
final class LaunchAgentController {
    static let label = "com.shutscreendown.app"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var domainTarget: String { "gui/\(getuid())" }
    private static var serviceTarget: String { "gui/\(getuid())/\(label)" }

    /// 安装开机自启（写 plist）。executablePath 必须是 App 内可执行文件的绝对路径。
    static func install(executablePath: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try plistContents(executablePath: executablePath)
                .write(to: plistURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// 移除开机自启（若当前正被 launchd 运行，先 bootout 停掉）。
    static func uninstall() {
        _ = bootout()
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 当前会话里 launchd 是否已加载本服务（说明「我」是被 launchd 拉起的）。
    static func isBootstrapped() -> Bool {
        launchctl(["print", serviceTarget]).status == 0
    }

    /// 从 launchd 会话卸载本服务（会终止本进程，调用后代码不会继续执行）。
    @discardableResult
    static func bootout() -> Bool {
        if !isBootstrapped() { return true }
        return launchctl(["bootout", serviceTarget]).status == 0
    }

    private static func plistContents(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "failed to run launchctl: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
