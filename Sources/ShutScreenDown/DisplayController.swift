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
            let v = CGDisplayVendorNumber(d)
            let p = CGDisplayModelNumber(d)
            let prefix = String(format: "%04X%02X%02X", v, p & 0xFF, (p >> 8) & 0xFF)
            return livePrefixes.contains(prefix)
        }
    }

    func hasUsableExternalDisplay() -> Bool { !usableExternalDisplays().isEmpty }

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
        case noExternal           // 安全拦截：没有外接显示器，拒绝关闭内置（否则全黑无法操作）
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
            case .beginFailed(let e):   return "开始配置失败 (CGError \(e))"
            case .configureFailed(let e): return "设置失败 (CGError \(e))"
            case .completeFailed(let e):  return "应用配置失败 (CGError \(e))"
            }
        }
    }

    // MARK: - 操作

    /// 关闭内置屏。**仅当存在在线外接显示器时**才会执行，否则返回 `.noExternal`。
    @discardableResult
    func disableBuiltin() -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard let builtin = builtinDisplay() else { return .noBuiltin }
        guard hasExternalDisplay() else { return .noExternal }
        return apply(fn, display: builtin, enabled: false)
    }

    /// 恢复内置屏
    @discardableResult
    func enableBuiltin() -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard let builtin = builtinDisplay() else { return .noBuiltin }
        return apply(fn, display: builtin, enabled: true)
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
