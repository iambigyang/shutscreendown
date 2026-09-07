import Foundation
import IOKit

/// 读取盖子开合状态。
/// 盖子状态是 IOPMrootDomain（电源管理根域，所有 Mac 都有）上的
/// "AppleClamshellState" 属性：true = 盖着，false = 开着，nil = 读不到。
enum LidState {
    static func isClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let raw = IORegistryEntryCreateCFProperty(service,
                                                  "AppleClamshellState" as CFString,
                                                  kCFAllocatorDefault, 0)
        return raw?.takeRetainedValue() as? Bool
    }
}
