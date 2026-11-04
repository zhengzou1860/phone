import AVFoundation
import Foundation

// MARK: - 麦克风这一摊
//
// 三件事分开：tap 线程只做「混成单声道 + 递出去」；FFT、判定、落盘全在 analysisQueue 这一条串行队列上；
// 界面上的实时数字再 hop 回主线程。这样 8 小时里既不会把音频线程堵住，也不会出现两个线程抢一份账本。
//
// 后台整夜录音靠的是 Info 里 UIBackgroundModes=audio ＋ 一个真的在跑的引擎。系统随时可能因为来电、Siri、
// 别的 app 抢麦、耳机插拔把引擎掐了——兜底的不是各种通知，而是那条 1 Hz 看门狗：
// 只要还想录、引擎却没转，就重设会话、重摘重装 tap、重开引擎。通知只是提前一点触发同一条路。

final class SnoreAudio {
    /// 块来了：单声道样本 + 这一块最后一个样本的会话内时刻（秒）。在 analysisQueue 上回调。
    var onBlock: (([Double], Double) -> Void)?
    /// 状态一句话（主线程回调）：给界面和磁盘流水用
    var onNote: ((String) -> Void)?

    private(set) var sampleRate = 48000.0
    private(set) var channelCount = 1
    private(set) var restarts = 0
    private(set) var wantRun = false
    private(set) var sessionStart = Date()
    private(set) var blocksDelivered = 0

    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "com.qoder.snorebench.analysis", qos: .utility)
    private var watchdog: Timer?
    private var startUptime = 0.0
    private var tapInstalled = false

    /// 会话和引擎这套东西不许两个线程同时动（看门狗、通知、按钮都可能碰）
    private let gate = NSLock()

    init() {
        // 通知一律不解析 userInfo（键名在各版本间挪过），听见了就走同一条重连路；
        // 真正的判据在 tick() 里：想录但引擎没转 ⇒ 重连。
        for name in ["AVAudioSessionInterruptionNotification",
                     "AVAudioSessionRouteChangeNotification",
                     "AVAudioEngineConfigurationChangeNotification"] {
            NotificationCenter.default.addObserver(self, selector: #selector(onSystemPoke),
                                                   name: Notification.Name(rawValue: name), object: nil)
        }
    }

    // MARK: 开停

    /// 先要麦克风权限，再开引擎。权限没给时 iOS 不报错，只是安静地给你一条全零——所以必须自己判。
    func start() {
        gate.lock()
        if wantRun { gate.unlock(); return }
        wantRun = true
        gate.unlock()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginNow()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.beginNow()
                    } else {
                        self.gate.lock()
                        self.wantRun = false
                        self.gate.unlock()
                        self.note("麦克风权限没给：设置 → 鼾声监测 → 麦克风改成「允许」。这一晚没录。")
                    }
                }
            }
        default:
            gate.lock()
            wantRun = false
            gate.unlock()
            note("麦克风权限被拒（当前 \(permText())）：去系统设置放开再点开始。")
        }
    }

    func stop() {
        gate.lock()
        wantRun = false
        gate.unlock()
        watchdog?.invalidate()
        watchdog = nil
        teardownEngine()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            note("收回音频会话时回了一句（不影响已存数据）：\(snoreErrText(error))")
        }
        note("停了：这一场递出 \(blocksDelivered) 块，引擎重连 \(restarts) 次")
    }

    private func beginNow() {
        gate.lock()
        guard wantRun else { gate.unlock(); return }
        gate.unlock()

        sessionStart = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        blocksDelivered = 0
        restarts = 0
        configureAndStart(why: "开始")

        watchdog?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    @objc private func onSystemPoke() {
        tick()
    }

    private func tick() {
        gate.lock()
        let want = wantRun
        gate.unlock()
        guard want else { return }
        if !engine.isRunning {
            restarts += 1
            configureAndStart(why: "看门狗第 \(restarts) 次重连")
        }
    }

    // MARK: 引擎

    private func configureAndStart(why: String) {
        gate.lock()
        defer { gate.unlock() }

        let session = AVAudioSession.sharedInstance()
        // .measurement：把系统的自动增益和压缩关掉，响度数才可比（默认模式会自己把声音拉平）
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            note("音频会话设不下去（\(why)）：\(snoreErrText(error))")
        }

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        // sampleRate 读出 0 是这条路上最常见的坑：会话还没活就拿格式去装 tap，装上去就是静音
        if fmt.sampleRate <= 1000 {
            note("\(why)：输入格式读出 \(Int(fmt.sampleRate)) Hz，半秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.gate.lock()
                let want = self.wantRun
                self.gate.unlock()
                if want && !self.engine.isRunning { self.configureAndStart(why: "格式为 0 重试") }
            }
            return
        }
        sampleRate = fmt.sampleRate
        channelCount = Int(fmt.channelCount)

        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }

        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
            note("引擎起来了（\(why)）：\(Int(sampleRate)) Hz / \(channelCount) 声道，"
                 + "窗 4096 ⇒ 每秒 \(String(format: "%.1f", sampleRate / 4096.0)) 帧")
        } catch {
            note("引擎起不来（\(why)）：\(snoreErrText(error))")
        }
    }

    private func teardownEngine() {
        gate.lock()
        defer { gate.unlock() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let ch = Int(buffer.format.channelCount)
        var out = [Double](repeating: 0.0, count: frames)
        if ch <= 1 {
            let p = data[0]
            for i in 0..<frames { out[i] = Double(p[i]) }
        } else {
            for i in 0..<frames {
                var s = 0.0
                for c in 0..<ch { s += Double(data[c][i]) }
                out[i] = s / Double(ch)
            }
        }
        // 块的结束时刻用单调时钟算：半夜系统对表也不把时间轴拧一下
        let now = ProcessInfo.processInfo.systemUptime - startUptime
        blocksDelivered += 1
        let cb = onBlock
        analysisQueue.async { cb?(out, now) }
    }

    private func note(_ text: String) {
        let cb = onNote
        guard cb != nil else { return }
        if Thread.isMainThread {
            cb?(text)
        } else {
            DispatchQueue.main.async { cb?(text) }
        }
    }

    private func permText() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        default: return "未决"
        }
    }
}

func snoreErrText(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain)\(ns.code): \(ns.localizedDescription)"
}

// MARK: - 事件片段的环形缓冲
//
// 只把最近 8 s 的「块引用」留着（不复制样本，分析队列本来就要过一遍）。一次发作/中断结束后按时间窗截出来
// 写 wav，所以录到的是「事情本身＋前后各 1.5 s」，不是整晚——整夜连续 pcm 既吃盘又吃电，医学上也没必要。

final class SnoreSnippetRing {
    private struct Block {
        var startT: Double
        var endT: Double
        var samples: [Double]
        var rate: Double
    }

    private var blocks: [Block] = []
    private let keepSec: Double
    private var lastEndT: Double?

    init(keepSec: Double = 8.0) {
        self.keepSec = keepSec
    }

    func append(_ samples: [Double], endTime: Double, sampleRate: Double) {
        if let last = lastEndT, endTime - last > 1.0 {
            // 引擎断过：中间缺了一段，新旧拼起来是假声音，整环丢掉
            blocks.removeAll()
        }
        let startT = endTime - Double(samples.count) / sampleRate
        blocks.append(Block(startT: startT, endT: endTime, samples: samples, rate: sampleRate))
        lastEndT = endTime
        let floorT = endTime - keepSec
        var drop = 0
        while drop < blocks.count && blocks[drop].endT < floorT { drop += 1 }
        if drop > 0 { blocks.removeFirst(drop) }
    }

    func clear() {
        blocks.removeAll()
        lastEndT = nil
    }

    /// 取 [from, to] 那一段；被裁掉了就拿不到，调用方按「这段没留成」记一笔。
    func capture(from: Double, to: Double) -> (samples: [Double], rate: Double)? {
        guard let first = blocks.first, let last = blocks.last else { return nil }
        let lo = max(from, first.startT)
        let hi = min(to, last.endT)
        guard hi - lo >= 0.3 else { return nil }
        var out: [Double] = []
        var rate = 48000.0
        for b in blocks {
            rate = b.rate
            let a = max(lo, b.startT)
            let z = min(hi, b.endT)
            if z <= a { continue }
            let iFrom = max(0, min(b.samples.count, Int((a - b.startT) * b.rate)))
            let iTo = max(iFrom, min(b.samples.count, Int((z - b.startT) * b.rate)))
            if iTo > iFrom { out.append(contentsOf: b.samples[iFrom..<iTo]) }
        }
        return out.isEmpty ? nil : (out, rate)
    }
}

// MARK: - WAV 落盘（自己写头，不碰 AVAudioFile）

enum SnoreWav {
    /// 线性插值降采样。鼾声谐波主要在 1.5 kHz 以下，16 k 单声道回放够用，一晚几百条也只占几十 MB。
    static func resample(_ input: [Double], from: Double, to: Double) -> [Double] {
        guard to < from, input.count > 2 else { return input }
        let ratio = from / to
        let count = max(1, Int(Double(input.count) / ratio))
        var out = [Double](repeating: 0.0, count: count)
        for i in 0..<count {
            let pos = Double(i) * ratio
            let k = Int(pos)
            if k + 1 < input.count {
                let frac = pos - Double(k)
                out[i] = input[k] * (1.0 - frac) + input[k + 1] * frac
            } else {
                out[i] = input[min(k, input.count - 1)]
            }
        }
        return out
    }

    /// 44 字节 PCM 头 + 16 bit 单声道小端。
    static func write(_ samples: [Double], sampleRate: Double, to url: URL) -> Bool {
        let sr = Int(sampleRate.rounded())
        guard sr >= 8000, !samples.isEmpty else { return false }
        var pcm = Data(capacity: samples.count * 2)
        for v in samples {
            var x = v
            if x > 1.0 { x = 1.0 }
            if x < -1.0 { x = -1.0 }
            let i = Int16(x * 32767.0)
            var le = UInt16(bitPattern: i).littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        let dataLen = UInt32(pcm.count)
        var all = Data()
        all.append("RIFF".data(using: .ascii)!)
        all.append(le32(36 + dataLen))
        all.append("WAVE".data(using: .ascii)!)
        all.append("fmt ".data(using: .ascii)!)
        all.append(le32(16))
        all.append(le16(1))
        all.append(le16(1))
        all.append(le32(UInt32(sr)))
        all.append(le32(UInt32(sr * 2)))
        all.append(le16(2))
        all.append(le16(16))
        all.append("data".data(using: .ascii)!)
        all.append(le32(dataLen))
        all.append(pcm)
        do {
            try all.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: MemoryLayout<UInt16>.size)
    }

    private static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: MemoryLayout<UInt32>.size)
    }
}
