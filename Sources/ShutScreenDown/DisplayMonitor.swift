import AppKit
import CoreGraphics
import Foundation

/// 显示器拓扑变化 / 系统唤醒 的统一监听。
///
/// 一次拔插会触发一串底层事件，这里做 0.3 秒防抖合并成一次回调；
/// 之后 1 秒、3 秒再各补一次确认，覆盖「开盖瞬间内屏晚点亮」这类过渡态。
/// 1.5 秒看门狗（AppDelegate 内）仍保留作最终兜底。
final class DisplayMonitor {

    /// 防抖后触发（主线程）。回调幂等，可放心多次调用。
    var onChange: (() -> Void)?

    private var generation = 0
    private var started = false

    private let reconfigCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
        guard let userInfo else { return }
        let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async { monitor.scheduleChange() }
    }

    func start() {
        guard !started else { return }
        started = true
        CGDisplayRegisterReconfigurationCallback(reconfigCallback, Unmanaged.passUnretained(self).toOpaque())

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    func stop() {
        guard started else { return }
        started = false
        CGDisplayRemoveReconfigurationCallback(reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        generation += 1   // 使未决的防抖回调失效
    }

    @objc private func screensChanged() { scheduleChange() }
    @objc private func handleWake() { scheduleChange() }

    /// 防抖：0.3 秒内再次触发则重置计时；触发后再 1s、3s 各补一次确认。
    private func scheduleChange() {
        generation += 1
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.onChange?()
            for delay in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.onChange?()
                }
            }
        }
    }

    deinit { stop() }
}
