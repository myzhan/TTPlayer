import Foundation

/// 一台内置电台（requirements F11 的出厂内容）。
///
/// `address` 存字符串而不是 `URL`：入表一律走 `RadioURL.normalize` 那一条口子，
/// 与用户手输、m3u 导进来的地址共用同一个校验与同一个身份写法（电台的 `identityKey`
/// 就是完整地址），内置的东西没有资格绕过它单开一套。
struct RadioPreset {
    let name: String
    let address: String

    /// 归一化不出来的内置地址就是代码里写错了（自检钉住这一条，运行时不该遇到）
    var url: URL? { RadioURL.normalize(address) }
    /// 拿它跟 `Track.identityKey` / 台名表的键对齐
    var identityKey: String { url?.absoluteString ?? address }
}

/// 内置电台清单（出厂内容）。
///
/// 启动时由 `PlayerController.seedPresetRadios` 默认塞进 [默认] 列表：入口埋得深的东西
/// 等于没有，用户不需要就在列表里把它删掉，删过的那台记进黑名单、以后每次启动都不再
/// 塞回来（`AppState.declinedRadioKeys`）。这一份仍然只是「台名 + 地址表」，
/// 既不自己写存档也不自己连网，入表一律走 `PlayerController.addRadio` 那条正常口子。
///
/// 台名也不写进 `RadioStations.aliases`（那张表记的是用户自己起的名字）：
/// 显示时按地址兜底，所以加过又删掉、或者从来没见过这个台，存档里都不会多出一条别名。
enum RadioPresets {
    static let all: [RadioPreset] = [
        RadioPreset(name: "Whispering Solo Piano Radio",
                    address: "https://pianosolo.streamguys1.com/live"),
    ]

    /// 这个地址是不是出厂自带的那一台（是 → 显示名走内置台名）
    static func name(for url: URL) -> String? {
        let key = url.absoluteString
        return all.first { $0.identityKey == key }?.name
    }
}
