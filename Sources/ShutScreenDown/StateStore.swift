import Foundation

/// App 落盘状态：进程崩溃 / 重启后仍记得自己的意图与设置。
struct AppState: Codable, Equatable {
    /// App 想让内置屏保持关闭（App 状态是唯一权威，盖子开合不改变它）
    var intentDisabled: Bool
    /// 自动模式：接外显自动关、拔掉自动恢复
    var autoMode: Bool
    /// 重插记忆：手动关闭后因拔线被迫恢复 → 下次插入外显时自动重新关闭
    var pendingReapply: Bool
    /// 自动模式下用户手动恢复了内屏 → 本次外接期间不再自动关（外显断开后清除）
    var autoHold: Bool

    static let defaultState = AppState(intentDisabled: false,
                                       autoMode: false,
                                       pendingReapply: false,
                                       autoHold: false)
}

/// 负责 AppState 的读写（~/Library/Application Support/ShutScreenDown/state.json）。
final class StateStore {
    private let url: URL
    private(set) var state: AppState

    init(url: URL? = nil) {
        self.url = url ?? StateStore.defaultURL()
        self.state = StateStore.read(from: self.url) ?? .defaultState
    }

    /// 修改状态并立即落盘。
    func update(_ mutate: (inout AppState) -> Void) {
        mutate(&state)
        persist()
    }

    func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("ShutScreenDown: 状态写入失败: \(error)")
        }
    }

    private static func read(from url: URL) -> AppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppState.self, from: data)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ShutScreenDown/state.json")
    }
}
