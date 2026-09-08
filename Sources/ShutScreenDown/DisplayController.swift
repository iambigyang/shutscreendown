import CoreGraphics
import Foundation
import IOKit

/// 封装对内置 / 外接显示器的启用、禁用与查询。
///
/// 通过 CoreGraphics 私有符号 `CGSConfigureDisplayEnabled` 真正关闭内置面板
/// （停止渲染 + 关闭背光），效果等同合盖（clamshell），但盖子保持打开。
final class DisplayController {

    /// CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
    typealias ConfigureDisplayEnabledFn =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    /// CGError CGSGetDisplayList(UInt32, CGDirectDisplayID*, UInt32*) —— 能列出「被禁用」的显示器
    typealias GetListFn =
        @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private let configureEnabled: ConfigureDisplayEnabledFn?
    private let getCGSList: GetListFn?

    /// 内置屏 ID 缓存。
    /// 内置屏被禁用后会从 CGGetOnlineDisplayList 中消失（Apple Silicon 实测如此），
    /// 不缓存它的 ID 就无法再找到它、恢复它。
    private var cachedBuiltinID: CGDirectDisplayID?

    init() {
        // RTLD_DEFAULT (== -2)：符号随 CoreGraphics 已载入本进程，直接取即可
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(rtldDefault, "CGSConfigureDisplayEnabled") {
            configureEnabled = unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
        } else {
            configureEnabled = nil
        }
        if let sym = dlsym(rtldDefault, "CGSGetDisplayList") {
            getCGSList = unsafeBitCast(sym, to: GetListFn.self)
        } else {
            getCGSList = nil
        }
    }

    /// 私有 API 是否可用（理论上所有现代 macOS 都可用）
    var isAPIAvailable: Bool { configureEnabled != nil }

    // MARK: - 查询

    func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// 所有显示器（含被禁用的）。拿不到 CGSGetDisplayList 就退回 online 列表。
    func allDisplays() -> [CGDirectDisplayID] {
        if let getCGSList {
            var count: UInt32 = 0
            if getCGSList(0, nil, &count) == .success, count > 0 {
                var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
                if getCGSList(count, &ids, &count) == .success {
                    return Array(ids.prefix(Int(count)))
                }
            }
        }
        return onlineDisplays()
    }

    /// 查找内置屏：在线列表优先；不在线就用缓存；冷启动（内置屏已被禁用）用全量列表兜底。
    func builtinDisplay() -> CGDirectDisplayID? {
        if let b = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            cachedBuiltinID = b
            return b
        }
        if let cachedBuiltinID { return cachedBuiltinID }
        if let b = allDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            cachedBuiltinID = b
            return b
        }
        return nil
    }

    /// 在线的外接显示器（非内置）
    func externalDisplays() -> [CGDirectDisplayID] {
        onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
    }

    func hasExternalDisplay() -> Bool { !externalDisplays().isEmpty }

    /// 「可用」外接显示器：在线、未休眠、且有真实物理连接。
    ///
    /// 物理连接判定：Apple Silicon 上每个外接显示端口对应 IORegistry 里的
    /// AppleDCPDPTXRemotePortUFP 服务，其 DisplayHints 里的 "EDID UUID" 前 8 位
    /// 编码了显示器的厂商号+产品号。拔掉扩展坞后这些服务随连接一起消失，
    /// 从而识别 CG 在线列表里残留的「幽灵显示器」（实测：内屏被禁用时拔线会出现）。
    /// 枚举不到任何端口服务时（结构变化 / 非 Apple Silicon）视为「无法判定」，
    /// 退化为仅检查休眠标志，不影响基本功能。
    func usableExternalDisplays() -> [CGDirectDisplayID] {
        let livePrefixes = liveDCPEdidPrefixes()
        return externalDisplays().filter { d in
            guard CGDisplayIsAsleep(d) == 0 else { return false }
            guard let livePrefixes else { return true }
            return livePrefixes.contains(vendorProductPrefix(d))
        }
    }

    func hasUsableExternalDisplay() -> Bool { !usableExternalDisplays().isEmpty }

    /// 物理在连的外接显示器（**含被禁用的**）：在 allDisplays 中且厂商/产品号
    /// 与 DCP 端口的 EDID 匹配。用于识别「孤儿」——集合成员被剔除后，
    /// 系统会话配置仍维持禁用状态的显示器（App 失忆但屏幕还黑着）。
    func physicallyConnectedExternals() -> [CGDirectDisplayID] {
        let livePrefixes = liveDCPEdidPrefixes()
        return allDisplays().filter { d in
            guard CGDisplayIsBuiltin(d) == 0 else { return false }
            guard let livePrefixes else { return true }
            return livePrefixes.contains(vendorProductPrefix(d))
        }
    }

    /// 显示器厂商+产品号 → EDID UUID 前缀（与 DCP 端口服务的 EDID UUID 前 8 位对应）。
    private func vendorProductPrefix(_ d: CGDirectDisplayID) -> String {
        let v = CGDisplayVendorNumber(d)
        let p = CGDisplayModelNumber(d)
        return String(format: "%04X%02X%02X", v, p & 0xFF, (p >> 8) & 0xFF)
    }

    /// 收集物理在连的 DCP 外接端口的 EDID UUID 前缀。见 usableExternalDisplays 注释。
    private func liveDCPEdidPrefixes() -> Set<String>? {
        var prefixes = Set<String>()
        var foundAny = false
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDCPDPTXRemotePortUFP"),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            foundAny = true
            defer { IOObjectRelease(svc) }
            var dict: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS else { continue }
            guard let props = dict?.takeRetainedValue() as? [String: Any],
                  let hints = props["DisplayHints"] as? [String: Any],
                  let uuid = hints["EDID UUID"] as? String else { continue }
            prefixes.insert(String(uuid.prefix(8)))
        }
        return foundAny ? prefixes : nil
    }

    /// 单行描述在线显示器（含每台的 活动/休眠 标志），用于拓扑日志。
    func describeDisplays() -> String {
        onlineDisplays().map { d in
            let kind = CGDisplayIsBuiltin(d) != 0 ? "内" : "外"
            let a = CGDisplayIsActive(d) != 0 ? 1 : 0
            let s = CGDisplayIsAsleep(d) != 0 ? 1 : 0
            return "\(d)\(kind)a\(a)s\(s)"
        }.joined(separator: " ")
    }

    /// 内置屏当前是否处于活动（渲染）状态
    func isBuiltinActive() -> Bool {
        guard let b = builtinDisplay() else { return false }
        return CGDisplayIsActive(b) != 0
    }

    // MARK: - 操作结果

    enum Result: Equatable {
        case ok
        case apiMissing
        case noBuiltin
        case noExternal           // 已废弃，保留枚举值以兼容日志（现由 wouldBlackout 统一拦截）
        case wouldBlackout        // 统一安全闸拦截：关闭后将无任何可见屏幕
        case beginFailed(Int32)
        case configureFailed(Int32)
        case completeFailed(Int32)

        var isSuccess: Bool { self == .ok }

        var message: String {
            switch self {
            case .ok:                   return "成功"
            case .apiMissing:           return "当前系统不支持该接口"
            case .noBuiltin:            return "未找到内置显示器"
            case .noExternal:           return "没有外接显示器，已拒绝（否则会全黑）"
            case .wouldBlackout:        return "这是最后一块可见屏幕，已拒绝关闭（否则会全黑无法操作）"
            case .beginFailed(let e):   return "开始配置失败 (CGError \(e))"
            case .configureFailed(let e): return "设置失败 (CGError \(e))"
            case .completeFailed(let e):  return "应用配置失败 (CGError \(e))"
            }
        }
    }

    // MARK: - 统一安全闸

    /// 关闭 `display` 后，剩余「可见」显示器数量。
    /// 可见谓词 = active 且（外接需非休眠且物理在连，走 EDID 检测）。
    /// 用 active 而非 online：被禁用的显示器不在 online 列表，若按 online 计数
    /// 会出现「关掉外接 A 后仍可关内置屏 → 全黑」的黑洞组合。
    func visibleDisplaysExcluding(_ display: CGDirectDisplayID) -> Int {
        var count = 0
        if let b = builtinDisplay(), b != display, CGDisplayIsActive(b) != 0 {
            count += 1
        }
        for d in usableExternalDisplays() where d != display && CGDisplayIsActive(d) != 0 {
            count += 1
        }
        return count
    }

    /// 关闭该屏后是否无任何可见屏幕（安全闸谓词）。
    func wouldLeaveNoVisibleScreen(_ display: CGDirectDisplayID) -> Bool {
        visibleDisplaysExcluding(display) == 0
    }

    // MARK: - 操作

    /// 关闭任意一台显示器。**所有关闭路径（手动/自动/重关）都必须经过此闸**。
    @discardableResult
    func disable(display: CGDirectDisplayID) -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard !wouldLeaveNoVisibleScreen(display) else { return .wouldBlackout }
        return apply(fn, display: display, enabled: false)
    }

    /// 恢复任意一台显示器。
    @discardableResult
    func enable(display: CGDirectDisplayID) -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        return apply(fn, display: display, enabled: true)
    }

    /// 批量恢复多台显示器（单次配置事务，避免 N 次 commit 造成 N 次全屏闪烁）。
    @discardableResult
    func enableAll(displays: [CGDirectDisplayID]) -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard !displays.isEmpty else { return .ok }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        if begin != .success { return .beginFailed(begin.rawValue) }
        for d in displays {
            let e = fn(config, d, true)
            if e != .success {
                CGCancelDisplayConfiguration(config)
                return .configureFailed(e.rawValue)
            }
        }
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        if complete != .success { return .completeFailed(complete.rawValue) }
        return .ok
    }

    /// 关闭内置屏（统一安全闸负责拦截「无其它可见屏」的场景）。
    @discardableResult
    func disableBuiltin() -> Result {
        guard let builtin = builtinDisplay() else { return .noBuiltin }
        return disable(display: builtin)
    }

    /// 恢复内置屏
    @discardableResult
    func enableBuiltin() -> Result {
        guard let builtin = builtinDisplay() else { return .noBuiltin }
        return enable(display: builtin)
    }

    private func apply(_ fn: ConfigureDisplayEnabledFn,
                       display: CGDirectDisplayID,
                       enabled: Bool) -> Result {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        if begin != .success { return .beginFailed(begin.rawValue) }

        let e = fn(config, display, enabled)
        if e != .success {
            CGCancelDisplayConfiguration(config)
            return .configureFailed(e.rawValue)
        }

        // .forSession：当前登录会话内持久（App 退出后仍生效），注销/重启自动恢复 —— 最安全
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        if complete != .success { return .completeFailed(complete.rawValue) }
        return .ok
    }
}
