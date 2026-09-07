import AppKit
import Darwin

// 单实例保护：已有实例在跑就直接退出。
// 由 launchd 拉起时同样适用：手动双击 App 产生的第二个实例不会与守护实例互搏。
let bundleID = Bundle.main.bundleIdentifier ?? "com.shutscreendown.app"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .contains(where: { $0 != NSRunningApplication.current }) {
    exit(0)
}

// 菜单栏 App 入口。delegate 用顶层常量持有，防止被释放。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
