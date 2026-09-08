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
    /// 被 App 关闭的外接显示器 ID 集合（外接覆盖层）。
    /// 剔除规则：既不在 allDisplays 也不在 online 列表才剔除——幽灵窗口期保留成员，
    /// 同端口插回 ID 复用时自动重新关闭（「关了就是关了」政策）。
    var disabledExternals: Set<UInt32>

    static let defaultState = AppState(intentDisabled: false,
                                       autoMode: false,
                                       pendingReapply: false,
                                       autoHold: false,
                                       disabledExternals: [])

    init(intentDisabled: Bool, autoMode: Bool, pendingReapply: Bool, autoHold: Bool,
         disabledExternals: Set<UInt32>) {
        self.intentDisabled = intentDisabled
        self.autoMode = autoMode
        self.pendingReapply = pendingReapply
        self.autoHold = autoHold
        self.disabledExternals = disabledExternals
    }

    /// 兼容旧版 state.json：缺 disabledExternals 键时默认空集（纯增量，无迁移风险）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intentDisabled = try c.decode(Bool.self, forKey: .intentDisabled)
        autoMode = try c.decode(Bool.self, forKey: .autoMode)
        pendingReapply = try c.decode(Bool.self, forKey: .pendingReapply)
        autoHold = try c.decode(Bool.self, forKey: .autoHold)
        disabledExternals = try c.decodeIfPresent(Set<UInt32>.self, forKey: .disabledExternals) ?? []
    }
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
