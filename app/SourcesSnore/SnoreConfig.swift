import Foundation

// MARK: - 界面上能改的那几档
//
// 整份 JSON 存在 UserDefaults 的一个键里：加了新字段也不影响老存档（decode 用默认值兜）。
// 这一层和 SnoreDetect/SnoreTrack 都不许碰 UIKit/AVFoundation——同一份代码要在 CI 那台 mac 上
// 拿合成信号跑自检（见 ci/snoreselftest/main.swift），那边没有模拟器也没有麦克风。

struct SnoreConfig: Codable, Equatable {
    /// 灵敏度：0 低 1 中 2 高。只挪「逐帧算鼾」的进门线，出门线跟着低 0.16（迟滞，防抖）。
    var sensitivity: Int = 1
    /// 鼾声停了多久算一次「疑似中断」（秒）。8 / 10 / 15 三档。
    var interruptGapSec: Double = 10
    /// 一次发作中间允许的短停（秒）：超过它就不算同一次发作。2.0 / 2.5 / 4.0。
    /// 这一档不能图小：鼾本身按呼吸周期一鼾一鼾地跳，两三秒的空是同一觉里的正常间隔，
    /// 设成 1 秒会把一晚连续打鼾劈成上千次「发作」，【发作次数/小时】就成了废数。
    /// 默认从 2.5 提到 4.0：拿「每口气都不一样」的不规则鼾压过一遍，它的空档实测 1.7–3.3 s，
    /// 2.5 会把一整段 100 s 的连续鼾劈成 9 次「发作」（次数/小时虚高 3 倍、节律也被打断）；
    /// 4.0 那边同一晚只出 1 段 98 s、节律 19.4 次/分。
    var boutGapSec: Double = 4
    /// 绝对门限（dBFS）：比本底高、但整晚其实听不见的极轻声音不算数。
    var absGateDb: Double = -58
    /// 短于这个时长的「鼾」当咳嗽／关门一类瞬发，不计入发作。
    var minBoutSec: Double = 0.5
    /// 事件要不要留 6 秒音频片段（能回放给医生听）。
    var keepSnippets: Bool = true
    /// 本地保留多少个晚上，超出的从旧到新删。
    var keepNights: Int = 14
    /// dBFS → 近似 dB(SPL) 的偏移。没拿声级计对过一次就留 0，报告会写明「相对刻度」。
    var calOffsetDb: Double = 0

    static let defaultsKey = "snore.config.v1"

    /// 三档灵敏度对应的进门分。
    var enterScore: Double {
        switch sensitivityClamped {
        case 0: return 0.68
        case 2: return 0.52
        default: return 0.60
        }
    }

    /// 出门线：比进门线低一档，声音在两条线之间晃时不会一次发作被劈成两半。
    var exitScore: Double { max(0.05, enterScore - 0.16) }

    var sensitivityClamped: Int { min(2, max(0, sensitivity)) }

    static func load() -> SnoreConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return SnoreConfig() }
        return (try? JSONDecoder().decode(SnoreConfig.self, from: data)) ?? SnoreConfig()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: SnoreConfig.defaultsKey)
        }
    }
}

// MARK: - 小算子

func snoreClamp01(_ v: Double) -> Double {
    if v.isNaN { return 0 }
    if v < 0 { return 0 }
    if v > 1 { return 1 }
    return v
}

/// 满量程正弦的 RMS 是 0.707 ⇒ 0 dBFS。静音给一个够用的地板，别让 log10(0) 变成 -inf。
func snoreDbfs(rms: Double) -> Double {
    guard rms > 1e-9 else { return -120 }
    return 20.0 * log10(rms)
}

func snoreDbfs(peak: Double) -> Double {
    guard peak > 1e-9 else { return -120 }
    return 20.0 * log10(peak)
}

func snoreMedian(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    let h = s.count / 2
    if s.count % 2 == 1 { return s[h] }
    return (s[h - 1] + s[h]) / 2.0
}

/// p 取 0...1。分位数用在「本底中位」这类地方：打鼾那一晚的最响几秒不该决定本底。
func snorePercentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    let idx = Int((Double(s.count - 1) * snoreClamp01(p)).rounded())
    return s[idx]
}

func snoreMean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    var sum = 0.0
    for v in values { sum += v }
    return sum / Double(values.count)
}

/// 秒 → "1 h 23 min" / "4 min 02 s" / "12.4 s"。报告里到处要用，口径统一在这一处。
func snoreDurText(_ seconds: Double) -> String {
    let s = max(0, seconds)
    if s < 60 { return String(format: "%.1f s", s) }
    let total = Int(s.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let sec = total % 60
    if h > 0 { return String(format: "%d h %02d min", h, m) }
    return String(format: "%d min %02d s", m, sec)
}

func snoreClockText(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

func snoreDateText(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: date)
}
