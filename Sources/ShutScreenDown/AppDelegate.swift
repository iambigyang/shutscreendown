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
        logger.log("启动。intentDisabled=\(store.state.intentDisabled) autoMode=\(store.state.autoMode) pendingReapply=\(store.state.pendingReapply) autoHold=\(store.state.autoHold)")

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
        // 兜底：经其它途径终止（非菜单退出）时也恢复内置屏。
        // 无条件恢复：意图可能与现实脱节（唤醒过渡期系统可能重放旧配置），
        // 退出契约是「内置屏亮着离开」，以现实为准（幂等，无副作用）。
        controller.enableBuiltin()
        logger.log("进程终止：恢复内置屏")
        store.update { s in
            s.intentDisabled = false
            s.pendingReapply = false
            s.autoHold = false
        }
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
        case .noExternal:
            notify("无法关闭内置屏", "请先连接外接显示器，否则屏幕会全黑、无法操作。")
        default:
            logger.log("手动关闭失败：\(r.message)")
            notify("关闭失败", r.message)
        }
        refresh()
    }

    @objc private func enable() {
        let r = controller.enableBuiltin()
        logger.log("手动恢复内置屏：\(r.message)")
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
        // 无条件恢复：退出契约是「内置屏亮着离开」，以现实为准（幂等）。
        controller.enableBuiltin()
        store.update { s in
            s.intentDisabled = false
            s.pendingReapply = false
            s.autoHold = false
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
        let builtinActive = controller.isBuiltinActive()
        let lidClosed = LidState.isClosed()
        var changed = false

        // 拓扑变化记录（仅变化时）：用于排查「事件是否被观察到」「幽灵显示器」类问题
        let topo = "可用外显\(hasUsableExt ? "有" : "无")/内置\(builtinActive ? "亮" : "熄")/盖子\(lidClosed.map { $0 ? "关" : "开" } ?? "?")/休眠\(screensAsleep ? "是" : "否")/[\(controller.describeDisplays())]"
        if topo != lastTopo {
            logger.log("\(reason)：拓扑 \(topo)")
            lastTopo = topo
        }

        // A. 自动模式：可用外显在、内屏亮着、用户没压着 → 自动关
        if s.autoMode && !s.autoHold && hasUsableExt && builtinActive {
            if controller.disableBuiltin().isSuccess {
                s.intentDisabled = true
                changed = true
                logger.log("\(reason)：自动模式关闭内置屏")
            }
        }

        // B. 意图=关 的维护
        if s.intentDisabled {
            if hasUsableExt {
                // 可用外显在但内屏被系统点亮（唤醒 / 开盖）→ 立即重新关掉
                if builtinActive {
                    if controller.disableBuiltin().isSuccess {
                        changed = true
                        logger.log("\(reason)：内屏被点亮，重新关闭")
                    }
                }
            } else if !screensAsleep {
                // 没有可用外显，且系统不在「显示休眠」中
                if builtinActive {
                    // macOS 在拔线时已自行点亮内屏（原生兜底）→ 采纳为开启，
                    // 同时把「启用」写回会话配置，防止唤醒过渡期系统重放旧的禁用配置
                    _ = controller.enableBuiltin()
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
                if controller.disableBuiltin().isSuccess {
                    s.pendingReapply = false
                    s.intentDisabled = true
                    changed = true
                    logger.log("\(reason)：外显重连，重新关闭内置屏（重插记忆）")
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
        content.title = "熄内屏"
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
        let symbol = off ? "laptopcomputer.slash" : "laptopcomputer"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "熄内屏") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = off ? "▣" : "▢"
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
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

        // —— 主开关 ——
        if builtinActive {
            let item = NSMenuItem(title: "关闭内置屏（只用外接）",
                                  action: #selector(disable), keyEquivalent: "d")
            item.target = self
            item.isEnabled = hasExt && controller.isAPIAvailable
            if !hasExt { item.toolTip = "需要先连接外接显示器" }
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "恢复内置屏",
                                  action: #selector(enable), keyEquivalent: "e")
            item.target = self
            item.isEnabled = controller.isAPIAvailable
            menu.addItem(item)
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

        let quitItem = NSMenuItem(title: "退出（自动恢复内置屏）",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "熄内屏 — 开盖只用外接显示器"
        a.informativeText = """
        盖子开着也能只用外接显示器（等效合盖模式），
        摄像头、Touch ID、键盘、散热均不受影响。

        行为约定：
        • 以内置屏开关状态为准：合盖、开盖都不会改变你的设置。
          设为「关」时，开盖瞬间屏幕亮一下后会自动重新关掉。
        • 没外接显示器时不会关闭内置屏；拔掉外接会自动恢复。
        • 退出 App 会自动恢复内置屏。

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
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}
