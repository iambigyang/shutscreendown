import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DisplayController()
    private let store = StateStore()
    private let logger = AppLogger.shared
    private let monitor = DisplayMonitor()
    private var statusItem: NSStatusItem!
    private var watchdog: Timer?
    /// 持有 activity 断言令牌：声明「用户主动使用」，防止 App Nap 节流计时器与事件送达
    private var activityToken: NSObjectProtocol?
    /// 上次的显示拓扑摘要，用于仅在变化时记录日志
    private var lastTopo: String?
    /// 治愈分支（E）上次尝试时间，用于限频
    private var lastHealAttempt = Date(timeIntervalSince1970: 0)
    /// F 分支限频：上次尝试重关外接的时间
    private var lastExternalReapplyAttempt = Date(timeIntervalSince1970: 0)
    /// F2 孤儿治愈限频：上次尝试治愈的时间
    private var lastExternalHealAttempt = Date(timeIntervalSince1970: 0)
    /// F 分支连续被安全闸拒绝的次数（≥3 采纳现实并通知）
    private var externalReapplyRejections = 0
    /// 菜单状态签名：仅变化时重建菜单，防止看门狗刷新导致菜单展开时闪动
    private var lastMenuSignature: String?
    /// 显示器显示名缓存：关屏后显示器不在线，NSScreen 查不到名字，用缓存兜底
    private var displayNameCache: [CGDirectDisplayID: String] = [:]

    /// 显示器显示名：优先系统型号名（NSScreen.localizedName，如「Kuycon G27P」）；
    /// 离线（被禁用）时用缓存；都拿不到时用分辨率或厂商/型号编号兜底。
    private func displayName(for d: CGDirectDisplayID) -> String {
        if let cached = displayNameCache[d], !cached.isEmpty { return cached }
        for screen in NSScreen.screens {
            let num = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            if num == d, !screen.localizedName.isEmpty {
                displayNameCache[d] = screen.localizedName
                return screen.localizedName
            }
        }
        let w = CGDisplayPixelsWide(d)
        let h = CGDisplayPixelsHigh(d)
        if w > 1 && h > 1 { return "\(w)×\(h)" }
        return String(format: "%04X:%04X", CGDisplayVendorNumber(d), CGDisplayModelNumber(d))
    }
    /// 系统是否处于「显示休眠」状态（所有屏幕睡觉）。
    /// 此时绝不点亮内置屏——否则空闲时会误伤（用户没动电脑，内屏自己亮了）。
    private var screensAsleep = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 仅菜单栏，无 Dock 图标
        // 阻止 App Nap：本 App 的正确性依赖「1.5 秒看门狗 + 显示器事件实时送达」，
        // 若被系统节流，拔掉外接屏时可能错过恢复窗口（曾实际发生过）。
        // .userInitiatedAllowingIdleSystemSleep：防 App Nap，但允许系统正常休眠。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "保持显示器事件与看门狗实时响应")
        logger.log("启动。intentDisabled=\(store.state.intentDisabled) autoMode=\(store.state.autoMode) pendingReapply=\(store.state.pendingReapply) autoHold=\(store.state.autoHold) disabledExternals=[\(store.state.disabledExternals.sorted().map(String.init).joined(separator: ","))]")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onChange = { [weak self] in self?.evaluate("显示事件") }
        monitor.start()

        // 跟踪显示休眠：休眠期间不做任何点亮内置屏的动作
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(screensSleeping),
                        name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screensWoke),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)
        let online = controller.onlineDisplays()
        screensAsleep = !online.isEmpty && online.allSatisfy { CGDisplayIsAsleep($0) != 0 }

        startWatchdog()
        setupNotifications()
        rebuildMenu()
        updateIcon()

        if !controller.isAPIAvailable {
            logger.log("错误：CGSConfigureDisplayEnabled 不可用")
            notify("当前系统不支持", "无法调用关闭内置屏所需的系统接口。")
        } else {
            evaluate("启动对账")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 兜底：经其它途径终止（非菜单退出）时也恢复所有显示器。
        // 无条件恢复：意图可能与现实脱节（唤醒过渡期系统可能重放旧配置），
        // 退出契约是「全部亮着离开」，以现实为准（幂等，无副作用）。
        restoreAllDisplays()
        logger.log("进程终止：恢复全部显示器")
        store.update { s in
            s.intentDisabled = false
            s.pendingReapply = false
            s.autoHold = false
            s.disabledExternals = []
        }
    }

    /// 批量恢复：内置屏 + 集合中「物理在连」的外接 + 物理在连但暗着的孤儿，
    /// 单次配置事务（避免 N 次闪烁）。退出契约：全部亮着离开。
    private func restoreAllDisplays() {
        let physical = Set(controller.physicallyConnectedExternals())
        var targets = controller.builtinDisplay().map { [$0] } ?? []
        // 集合成员必须过滤为「物理在连」：幽灵 ID 会让配置事务整体失败，
        // 导致一次都恢复不了（退出黑屏风险），宁可少恢复也不能全失败。
        for extID in store.state.disabledExternals {
            let d = CGDirectDisplayID(extID)
            if physical.contains(d), !targets.contains(d) {
                targets.append(d)
            }
        }
        for d in physical where !targets.contains(d) && CGDisplayIsActive(d) == 0 {
            targets.append(d)
        }
        guard !targets.isEmpty else { return }
        let r = controller.enableAll(displays: targets)
        logger.log("批量恢复显示器 \(targets.count) 台：\(r.message)")
    }

    // MARK: - 手动动作

    @objc private func disable() {
        let r = controller.disableBuiltin()
        switch r {
        case .ok:
            store.update { s in
                s.intentDisabled = true
                s.pendingReapply = false
                s.autoHold = false
            }
            logger.log("手动关闭内置屏")
        case .alreadyInState:
            logger.log("内置屏已是关闭状态，忽略重复操作")
            notify("内置屏已是关闭状态", "当前已经是关闭状态，无需重复操作。")
        case .wouldBlackout:
            logger.log("手动关闭内置屏被安全闸拒绝")
            notify("无法关闭内置屏", r.message)
        case .noExternal:
            notify("无法关闭内置屏", "请先连接外接显示器，否则屏幕会全黑、无法操作。")
        default:
            logger.log("手动关闭失败：\(r.message)")
            notify("关闭失败", r.message)
        }
        refresh()
    }

    /// 列表动作：关闭某台外接显示器（统一安全闸拦截最后一块可见屏）。
    @objc private func extDisable(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? CGDirectDisplayID else { return }
        let r = controller.disable(display: d)
        switch r {
        case .ok:
            store.update { $0.disabledExternals.insert(UInt32(d)) }
            logger.log("手动关闭外接显示器 \(d)")
        case .alreadyInState:
            logger.log("外接 \(d) 已是关闭状态，忽略重复操作")
            notify("\(displayName(for: d)) 已是关闭状态", "当前已经是关闭状态，无需重复操作。")
        case .wouldBlackout:
            logger.log("关闭外接 \(d) 被安全闸拒绝")
            notify("无法关闭", r.message)
        default:
            logger.log("关闭外接 \(d) 失败：\(r.message)")
            notify("关闭失败", r.message)
        }
        refresh()
    }

    /// 列表动作：开启某台外接显示器。
    @objc private func extEnable(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? CGDirectDisplayID else { return }
        let r = controller.enable(display: d)
        logger.log("手动开启外接显示器 \(d)：\(r.message)")
        if r.isSuccess {
            store.update { $0.disabledExternals.remove(UInt32(d)) }
            if r == .alreadyInState {
                notify("\(displayName(for: d)) 已是开启状态", "当前已经是开启状态，无需重复操作。")
            }
        } else {
            notify("开启失败", r.message)
        }
        refresh()
    }

    @objc private func enable() {
        let r = controller.enableBuiltin()
        logger.log("手动恢复内置屏：\(r.message)")
        if r == .alreadyInState {
            notify("内置屏已是开启状态", "当前已经是开启状态，无需重复操作。")
            refresh()
            return
        }
        if !r.isSuccess {
            notify("恢复失败", "\(r.message)\n\n若屏幕仍黑，可用「恢复内置屏」急救工具，或合盖再开盖、注销重启恢复。")
            refresh()
            return
        }
        store.update { s in
            s.intentDisabled = false
            s.pendingReapply = false
            // 自动模式下用户手动恢复 = 本次外接期间尊重用户选择，不再自动关
            s.autoHold = s.autoMode
        }
        refresh()
    }

    @objc private func toggleAuto() {
        store.update { s in
            s.autoMode.toggle()
            if !s.autoMode { s.autoHold = false }
        }
        logger.log("自动模式 → \(store.state.autoMode ? "开" : "关")")
        if store.state.autoMode { evaluate("自动模式开启") }
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        if LaunchAgentController.isInstalled() {
            LaunchAgentController.uninstall()
            logger.log("关闭开机自启")
        } else {
            let exe = Bundle.main.executablePath ?? ""
            if LaunchAgentController.install(executablePath: exe) {
                logger.log("开启开机自启：\(exe)")
            } else {
                notify("设置失败", "写入开机自启项失败。")
            }
        }
        rebuildMenu()
    }

    @objc private func quit() {
        logger.log("用户选择退出")
        // 顺序重要：先恢复屏幕、清状态，再 bootout —— bootout 会立刻终止本进程，
        // 走不到后面的代码，所以恢复动作必须放在它前面。
        // 无条件恢复：退出契约是「所有显示器亮着离开」，以现实为准（幂等）。
        restoreAllDisplays()
        store.update { s in
            s.intentDisabled = false
            s.pendingReapply = false
            s.autoHold = false
            s.disabledExternals = []
        }
        if LaunchAgentController.isBootstrapped() {
            logger.log("运行于 launchd，bootout 后退出（防止被 KeepAlive 拉起）")
            LaunchAgentController.bootout()
        }
        NSApp.terminate(nil)
    }

    // MARK: - 对账（核心状态机）

    /// 让现实（外接显示器 / 盖子 / 内屏状态）与 App 意图一致。
    /// 所有显示器变化、唤醒、看门狗最终都汇到这里；幂等，可任意次数调用。
    func evaluate(_ reason: String) {
        guard controller.isAPIAvailable else { refresh(); return }
        var s = store.state
        let hasUsableExt = controller.hasUsableExternalDisplay()
        var builtinActive = controller.isBuiltinActive()   // 可变：每次操作后同步刷新，避免同一轮重复操作同一块屏
        let lidClosed = LidState.isClosed()
        var changed = false

        // 拓扑变化记录（仅变化时）：用于排查「事件是否被观察到」「幽灵显示器」类问题
        let topo = "可用外显\(hasUsableExt ? "有" : "无")/内置\(builtinActive ? "亮" : "熄")/盖子\(lidClosed.map { $0 ? "关" : "开" } ?? "?")/休眠\(screensAsleep ? "是" : "否")/集合[\(s.disabledExternals.sorted().map(String.init).joined(separator: ","))]/[\(controller.describeDisplays())]"
        if topo != lastTopo {
            logger.log("\(reason)：拓扑 \(topo)")
            lastTopo = topo
        }

        // F. 外接意图维护（先于内置屏分支：顺序裁决写死，终态与事件顺序无关）
        let physicalExternals = controller.physicallyConnectedExternals()
        if !s.disabledExternals.isEmpty {
            let onlineIDs = Set(controller.onlineDisplays())
            let physicalIDs = Set(physicalExternals)
            var removed: [UInt32] = []
            for extID in s.disabledExternals {
                let d = CGDirectDisplayID(extID)
                // 剔除：不在线且无物理连接（物理拔出，或扩展坞残留的幽灵 ID）
                guard onlineIDs.contains(d) || physicalIDs.contains(d) else {
                    removed.append(extID)
                    continue
                }
                // 未点亮（active=0）或休眠中 → 无需动作
                guard !screensAsleep,
                      CGDisplayIsAsleep(d) == 0,
                      CGDisplayIsActive(d) != 0 else { continue }
                // 限频 10s，防系统反复重放配置导致的 commit 风暴
                guard Date().timeIntervalSince(lastExternalReapplyAttempt) > 10 else { continue }
                lastExternalReapplyAttempt = Date()
                let r = controller.disable(display: d)
                if r.isSuccess {
                    externalReapplyRejections = 0
                    changed = true
                    logger.log("\(reason)：外接 \(d) 被点亮，重新关闭")
                } else {
                    externalReapplyRejections += 1
                    logger.log("\(reason)：外接 \(d) 重关被拒（\(r.message)），第 \(externalReapplyRejections) 次")
                    if externalReapplyRejections >= 3 {
                        removed.append(extID)   // 连续被拒 → 采纳现实
                        externalReapplyRejections = 0
                        notify("外接显示器状态已更新", "无法维持显示器 \(d) 的关闭状态，已按系统状态恢复为开启。")
                    }
                }
            }
            if !removed.isEmpty {
                s.disabledExternals.subtract(removed)
                changed = true
                logger.log("\(reason)：外接集合剔除 \(removed)")
            }
        }

        // F2. 孤儿治愈：物理在连、未点亮、也不在集合中的外接（集合曾被剔除，
        // 但系统会话配置仍维持禁用）→ 恢复为亮，使现实与意图（未要求关闭）一致。
        if !screensAsleep && Date().timeIntervalSince(lastExternalHealAttempt) > 10 {
            for d in physicalExternals
                where !s.disabledExternals.contains(UInt32(d))
                    && CGDisplayIsActive(d) == 0
                    && CGDisplayIsAsleep(d) == 0 {
                lastExternalHealAttempt = Date()
                if controller.enable(display: d).isSuccess {
                    changed = true
                    logger.log("\(reason)：孤儿外接 \(d) 治愈恢复")
                }
                break   // 一次只处理一台，避免单次 evaluate 过多配置操作
            }
        }

        // A. 自动模式：可用外显在、内屏亮着、用户没压着 → 自动关
        if s.autoMode && !s.autoHold && hasUsableExt && builtinActive {
            let r = controller.disableBuiltin()
            if r.isSuccess {
                s.intentDisabled = true
                changed = true
                builtinActive = controller.isBuiltinActive()
                logger.log("\(reason)：自动模式关闭内置屏")
            } else {
                logger.log("\(reason)：自动模式关闭失败：\(r.message)")
            }
        }

        // B. 意图=关 的维护
        if s.intentDisabled {
            if hasUsableExt {
                // 可用外显在但内屏被系统点亮（唤醒 / 开盖）→ 立即重新关掉
                if builtinActive {
                    let r = controller.disableBuiltin()
                    if r.isSuccess {
                        changed = true
                        builtinActive = controller.isBuiltinActive()
                        logger.log("\(reason)：内屏被点亮，重新关闭")
                    } else {
                        logger.log("\(reason)：内屏重关失败：\(r.message)")
                    }
                }
            } else if !screensAsleep {
                // 没有可用外显，且系统不在「显示休眠」中
                if builtinActive {
                    // macOS 在拔线时已自行点亮内屏（原生兜底）→ 采纳为开启，
                    // 同时把「启用」写回会话配置，防止唤醒过渡期系统重放旧的禁用配置
                    if let b = controller.builtinDisplay() {
                        _ = controller.writeBackEnabled(display: b)
                    }
                    s.intentDisabled = false
                    if !s.autoMode { s.pendingReapply = true }   // 手动模式：记下重插记忆
                    changed = true
                    logger.log("\(reason)：外显断开且系统已点亮内屏，采纳为开启")
                    notifyRestored()
                } else if lidClosed == false || lidClosed == nil {
                    // 开盖（或盖子状态未知）且内屏暗着：不恢复就是全黑死局 → 恢复
                    let r = controller.enableBuiltin()
                    if r.isSuccess {
                        s.intentDisabled = false
                        if !s.autoMode { s.pendingReapply = true }   // 手动模式：记下重插记忆
                        changed = true
                        builtinActive = controller.isBuiltinActive()
                        logger.log("\(reason)：无外显且开盖，安全恢复内置屏")
                        notifyRestored()
                    } else {
                        logger.log("\(reason)：安全恢复失败：\(r.message)")
                    }
                }
                // 合盖：屏幕本来就黑（原生合盖模式），维持关闭意图，不动作
            }
        }

        // C. 重插记忆（手动模式）：拔线被迫恢复后，外显回来 → 自动重新关闭
        if !changed && s.pendingReapply && hasUsableExt {
            if builtinActive {
                let r = controller.disableBuiltin()
                if r.isSuccess {
                    s.pendingReapply = false
                    s.intentDisabled = true
                    changed = true
                    logger.log("\(reason)：外显重连，重新关闭内置屏（重插记忆）")
                } else {
                    logger.log("\(reason)：重插重关失败：\(r.message)")
                }
            } else {
                s.pendingReapply = false
                changed = true
            }
        }

        // D. 外显断开时清除 autoHold（下次连接重新尊重自动模式）
        if s.autoHold && !hasUsableExt {
            s.autoHold = false
            changed = true
        }

        // E. 治愈：意图=开 但内屏却暗着（如唤醒后系统重放了旧的禁用配置）→ 按意图恢复。
        // 仅开盖 + 有可用外显 + 非显示休眠时执行；限频防止配置写入刷屏。
        if !changed && !s.intentDisabled && !builtinActive
            && hasUsableExt && (lidClosed == false || lidClosed == nil)
            && !screensAsleep {
            if Date().timeIntervalSince(lastHealAttempt) > 10 {
                lastHealAttempt = Date()
                if controller.enableBuiltin().isSuccess {
                    changed = true
                    logger.log("\(reason)：意图为开但内屏暗着，治愈恢复")
                }
            }
        }

        if changed { store.update { $0 = s } }
        refresh()
    }

    @objc private func screensSleeping() {
        screensAsleep = true
        evaluate("屏幕休眠")
    }

    @objc private func screensWoke() {
        screensAsleep = false
        evaluate("屏幕唤醒")
    }

    // MARK: - 看门狗

    private func startWatchdog() {
        // .common 模式：菜单展开时也持续运行。兜底所有事件遗漏与偶发点亮。
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.evaluate("看门狗")
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    // MARK: - 通知

    private func setupNotifications() {
        // 首次启动会弹系统授权框，用户允许后恢复通知以横幅显示
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                AppLogger.shared.log("通知授权失败：\(error)")
            } else {
                AppLogger.shared.log("通知授权：\(granted ? "已允许" : "被拒绝")")
            }
        }
    }

    private func notifyRestored() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // 开发态（未打包）不发
        logger.log("发出恢复通知")
        let content = UNMutableNotificationContent()
        content.title = "熄屏"
        content.body = "外接显示器已断开，内置屏已恢复。"
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - UI

    private func refresh() {
        rebuildMenu()
        updateIcon()
    }

    private func updateIcon() {
        let off = store.state.intentDisabled || !controller.isBuiltinActive()
        if let img = MenuBarIcon.image(off: off) {
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = off ? "▣" : "▢"
        }
    }

    private func rebuildMenu(force: Bool = false) {
        guard let menu = statusItem.menu else { return }
        // 状态签名比对：看门狗每 1.5s 调 refresh，签名未变则不重建，防止菜单展开时闪动
        let signature = menuSignature()
        if !force, signature == lastMenuSignature { return }
        lastMenuSignature = signature
        menu.removeAllItems()

        let hasExt = controller.hasExternalDisplay()
        let builtinActive = controller.isBuiltinActive()
        let lid = LidState.isClosed()
        let s = store.state

        // —— 状态信息 ——
        let statusText: String
        if !controller.isAPIAvailable {
            statusText = "⚠︎ 当前系统不支持"
        } else if s.intentDisabled && !builtinActive {
            statusText = "内置屏：已关闭（仅外接）"
        } else if s.intentDisabled {
            statusText = "内置屏：关闭中（等待系统确认）"
        } else {
            statusText = "内置屏：开启中"
        }
        addInfo(menu, statusText)
        addInfo(menu, hasExt ? "外接显示器：\(controller.externalDisplays().count) 台已连接"
                             : "外接显示器：未连接")
        let lidText: String
        switch lid {
        case .some(true):  lidText = "盖子：关闭"
        case .some(false): lidText = "盖子：打开"
        case nil:          lidText = "盖子：未知"
        }
        addInfo(menu, lidText)
        menu.addItem(.separator())

        // —— 显示器列表 ——
        addInfo(menu, "显示器：")
        // 内置屏行：与外接屏行同构，展开子菜单可单独开关（无内置屏的机型如 Mac mini 不显示此行）
        if controller.builtinDisplay() != nil {
            menu.addItem(builtinMenuItem(state: s))
        }
        // 外接屏行：仅显示「在线外接 + 被 App 关闭（集合）的外接」，
        // 隐藏扩展坞残留的 1x1 幽灵条目（allDisplays 里的假显示器）。
        var shown = Set<CGDirectDisplayID>()
        for d in controller.externalDisplays() {
            shown.insert(d)
            menu.addItem(externalMenuItem(display: d, state: s))
        }
        for extID in s.disabledExternals.sorted() {
            let d = CGDirectDisplayID(extID)
            if !shown.contains(d) {
                shown.insert(d)
                menu.addItem(externalMenuItem(display: d, state: s))
            }
        }
        menu.addItem(.separator())

        // —— 自动模式 ——
        let auto = NSMenuItem(title: "自动：接外显关、拔掉恢复",
                              action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = s.autoMode ? .on : .off
        menu.addItem(auto)

        // —— 开机自启 ——
        let login = NSMenuItem(title: "开机自启（崩溃自动重启）",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAgentController.isInstalled() ? .on : .off
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            login.isEnabled = false
            login.toolTip = "打包成 App 后可用"
        }
        menu.addItem(login)

        menu.addItem(.separator())

        // —— 其它 ——
        let about = NSMenuItem(title: "关于 / 屏幕全黑怎么救",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quitItem = NSMenuItem(title: "退出（自动恢复全部显示器）",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 内置显示器行：与外接屏行同构，子菜单提供关闭/开启动作。
    private func builtinMenuItem(state s: AppState) -> NSMenuItem {
        let active = controller.isBuiltinActive()
        let item = NSMenuItem(title: "  内置显示器（\(active ? "开" : "关")）",
                              action: nil, keyEquivalent: "")
        item.toolTip = s.intentDisabled ? "意图：保持关闭" : "意图：保持开启"

        // 用统一安全闸而非 hasExternalDisplay：关掉全部外接后此开关必须不可用
        let canDisable = controller.builtinDisplay()
            .map { !controller.wouldLeaveNoVisibleScreen($0) } ?? false

        let sub = NSMenu()
        let offItem = NSMenuItem(title: "关闭内置屏", action: #selector(disable), keyEquivalent: "d")
        offItem.target = self
        offItem.isEnabled = active && canDisable && controller.isAPIAvailable
        offItem.toolTip = canDisable ? "关闭后只用外接显示器" : "没有其它可见屏幕，无法关闭"
        sub.addItem(offItem)
        let onItem = NSMenuItem(title: "开启内置屏", action: #selector(enable), keyEquivalent: "e")
        onItem.target = self
        onItem.isEnabled = !active && controller.isAPIAvailable
        sub.addItem(onItem)
        item.submenu = sub
        return item
    }

    /// 外接显示器行：标题带真实型号名与现实状态，子菜单提供关闭/开启动作。
    private func externalMenuItem(display d: CGDirectDisplayID, state s: AppState) -> NSMenuItem {
        _ = displayName(for: d)   // 在线时预热名称缓存（关屏后离线也能显示名字）
        let active = CGDisplayIsActive(d) != 0
        let online = controller.onlineDisplays().contains(d)
        let inSet = s.disabledExternals.contains(UInt32(d))
        let title = "  " + displayName(for: d)

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // 防御分支：正常构建流程不会走到（行只来自在线或集合），残留保护
        if !online && !active && !inSet {
            item.title = title + "（已断开）"
            item.isEnabled = false
            item.toolTip = "物理连接已断开"
            return item
        }
        item.title = title + (active ? "（开）" : "（关）")
        item.toolTip = inSet ? "意图：关闭" : (active ? "已开启" : "系统未点亮")

        let sub = NSMenu()
        let offItem = NSMenuItem(title: "关闭此显示器", action: #selector(extDisable(_:)), keyEquivalent: "")
        offItem.target = self
        offItem.representedObject = d
        offItem.isEnabled = active
        sub.addItem(offItem)
        let onItem = NSMenuItem(title: "开启此显示器", action: #selector(extEnable(_:)), keyEquivalent: "")
        onItem.target = self
        onItem.representedObject = d
        onItem.isEnabled = !active || inSet
        sub.addItem(onItem)
        item.submenu = sub
        return item
    }

    /// 菜单状态签名：与上次相同则跳过重建。
    private func menuSignature() -> String {
        let s = store.state
        return [
            String(controller.isAPIAvailable),
            String(controller.isBuiltinActive()),
            String(controller.externalDisplays().count),
            String(controller.hasUsableExternalDisplay()),
            String(describing: LidState.isClosed()),
            String(s.intentDisabled),
            String(s.autoMode),
            String(s.autoHold),
            String(s.pendingReapply),
            String(LaunchAgentController.isInstalled()),
            String(Bundle.main.bundlePath.hasSuffix(".app")),
            s.disabledExternals.sorted().map(String.init).joined(separator: ","),
            controller.describeDisplays(),
        ].joined(separator: "|")
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "熄屏 — 单独开关任意显示器"
        a.informativeText = """
        可以单独熄灭或点亮任意一块屏幕：
        关内置屏开盖只用外接显示器（等效合盖模式，
        摄像头、Touch ID、键盘、散热均不受影响），
        或关掉暂时不用的外接屏。

        行为约定：
        • 以内置屏开关状态为准：合盖、开盖都不会改变你的设置。
          设为「关」时，开盖瞬间屏幕亮一下后会自动重新关掉。
        • 显示器列表中展开任一显示器（含内置屏）即可单独关闭/开启；
          最后一块可见屏幕永远无法被关闭。
        • 没外接显示器时不会关闭内置屏；拔掉外接会自动恢复。
        • 退出 App 会自动恢复所有被关闭的显示器。

        万一屏幕全黑：
        1. 拔掉外接显示器（App 会自动恢复内置屏）
        2. Spotlight 盲打：⌘ 空格，输入「恢复内置屏」，回车
        3. 合盖再开盖，或注销 / 重启（设置仅本次登录会话有效，必然恢复）

        日志：~/Library/Logs/ShutScreenDown.log
        """
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func notify(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(force: true) }
}
