import Foundation

// MARK: - 清理范围

enum CleanCategory: String, CaseIterable, Identifiable, Sendable {
    case junk
    case model
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .junk: return "调试垃圾"
        case .model: return "模型冗余"
        case .history: return "旧成片与历史记录"
        }
    }

    var subtitle: String {
        switch self {
        case .junk:
            return "运行日志、容器 tmp / 共享临时区残留（含视频）、后缀 .tmp 的中断下载；6 小时内还在变的文件不动"
        case .model:
            return "旧模型包、旧版本编译缓存、没删掉的深度缓存；当前模型和下载中的 archive.part 一律保留"
        case .history:
            return "所有视频文件（含子目录和 tmp 里的）以及鼾声监测的旧一晚；默认不勾，保留几天由你填"
        }
    }
}

enum CleanFormat {
    static func bytes(_ n: Int64) -> String {
        if n <= 0 { return "0 B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return String(format: "%.0f KB", max(kb, 0.1)) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 白名单与发现

struct CleanerAppSpec: Sendable {
    let bundleID: String
    let name: String
}

struct CleanContainer: Sendable, Hashable {
    let url: URL
    let name: String
    let appIdentifier: String
    let isShared: Bool
}

struct CleanTarget: Sendable, Identifiable {
    let bundleID: String
    let name: String
    var containers: [CleanContainer]
    var id: String { bundleID }
}

struct CleanerEnv: Sendable {
    let lcHome: URL?
    let dataRoots: [URL]
    let tmpDir: URL
    let targets: [CleanTarget]
    let notes: [String]

    var insideLC: Bool { lcHome != nil }
    var containerCount: Int { targets.reduce(0) { $0 + $1.containers.count } }
}

enum CleanerDiscovery {
    // 只认这几个包名，完全相等才算；LiveContainer / SideStore 不在里面，所以天然碰不到。
    static let apps: [CleanerAppSpec] = [
        CleanerAppSpec(bundleID: "com.qoder.hellolc", name: "剪辑"),
        CleanerAppSpec(bundleID: "com.qoder.snorebench", name: "鼾声监测"),
        CleanerAppSpec(bundleID: "com.qoder.swapbench", name: "换脸出片"),
        CleanerAppSpec(bundleID: "com.qoder.vr3d", name: "VR3D"),
        CleanerAppSpec(bundleID: "com.qoder.voice", name: "语音"),
        CleanerAppSpec(bundleID: "com.qoder.liveswap", name: "直播"),
    ]

    static let forbiddenPrefixes = [
        "com.kdt.livecontainer",
        "com.SideStore",
        "com.rileytestut.AltStore",
    ]

    static func isForbidden(_ id: String) -> Bool {
        forbiddenPrefixes.contains { id.hasPrefix($0) }
    }

    static func isAllowed(_ id: String) -> Bool {
        !isForbidden(id) && apps.contains { $0.bundleID == id }
    }

    /// `homeHint` / `tmpDir` 只给自检用；手机上跑的时候传默认值，走环境变量和可执行文件位置。
    static func discover(homeHint: URL? = nil, tmpDir: URL? = nil) -> CleanerEnv {
        var notes: [String] = []
        var home: URL?

        if let hint = homeHint {
            if looksLikeLCHome(hint) {
                home = hint
            } else {
                notes.append("给的主目录不像 LiveContainer 主目录：\(hint.path)")
            }
        }
        if home == nil { home = findHome(notes: &notes) }

        var roots: [URL] = []
        if let home {
            let candidates = [
                home.appendingPathComponent("Documents/Data/Application", isDirectory: true),
                home.appendingPathComponent("LiveContainer/Documents/Data/Application", isDirectory: true),
                home.appendingPathComponent("LiveContainer/Data/Application", isDirectory: true),
                home.appendingPathComponent("Data/Application", isDirectory: true),
            ]
            for c in candidates where isDirectory(c) {
                let p = c.standardizedFileURL.path
                if !roots.contains(where: { $0.standardizedFileURL.path == p }) {
                    roots.append(c)
                }
            }
            if roots.isEmpty {
                notes.append("没找到 \(home.path)/Documents/Data/Application —— 助手需要和要清理的 app 装在同一个 LiveContainer 里")
            }
        } else {
            notes.append("没有 LC_HOME_PATH，也不在 LiveContainer 的 Applications 目录下：请把清理助手装进同一个 LiveContainer 再运行")
        }

        var found: [String: [CleanContainer]] = [:]
        let fm = FileManager.default
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []
            for dir in entries {
                guard let v = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      v.isSymbolicLink != true,
                      v.isDirectory == true else { continue }
                // 身份只认容器目录里的 LCContainerInfo.plist；读不出来或不在白名单，一律不进清单。
                guard let ident = containerIdentifier(dir), isAllowed(ident) else { continue }
                let container = CleanContainer(
                    url: dir,
                    name: dir.lastPathComponent,
                    appIdentifier: ident,
                    isShared: root.path.contains("/LiveContainer/")
                )
                found[ident, default: []].append(container)
            }
        }

        let targets = apps.map { spec -> CleanTarget in
            let list = (found[spec.bundleID] ?? []).sorted { $0.name < $1.name }
            return CleanTarget(bundleID: spec.bundleID, name: spec.name, containers: list)
        }

        if !roots.isEmpty {
            let total = targets.reduce(0) { $0 + $1.containers.count }
            if total == 0 {
                notes.append("数据目录里没找到这些 app 的容器（LCContainerInfo.plist 的 appIdentifier 对不上）")
            }
            for t in targets where t.containers.isEmpty {
                notes.append("没找到「\(t.name)」的数据容器，可能没装在这个 LiveContainer 里")
            }
        }

        return CleanerEnv(
            lcHome: home,
            dataRoots: roots,
            tmpDir: tmpDir ?? fm.temporaryDirectory,
            targets: targets,
            notes: notes
        )
    }

    private static func findHome(notes: inout [String]) -> URL? {
        let env = ProcessInfo.processInfo.environment
        for key in ["LC_HOME_PATH", "LP_HOME_PATH"] {
            guard let raw = env[key], !raw.isEmpty else { continue }
            let u = URL(fileURLWithPath: raw, isDirectory: true)
            if looksLikeLCHome(u) { return u }
            notes.append("\(key) 指向的目录不像 LiveContainer 主目录：\(raw)")
        }

        var u = Bundle.main.executableURL?.deletingLastPathComponent()
        var hops = 0
        while let cur = u, hops < 10 {
            if looksLikeLCHome(cur) { return cur }
            u = cur.deletingLastPathComponent()
            hops += 1
        }
        return nil
    }

    private static func looksLikeLCHome(_ url: URL) -> Bool {
        let fm = FileManager.default
        if isDirectory(url.appendingPathComponent("Documents/Data/Application", isDirectory: true)) { return true }
        if isDirectory(url.appendingPathComponent("Documents/Applications", isDirectory: true)) { return true }
        if isDirectory(url.appendingPathComponent("Data/Application", isDirectory: true)) { return true }
        if isDirectory(url.appendingPathComponent("LiveContainer/Data/Application", isDirectory: true)) { return true }
        return fm.fileExists(atPath: url.appendingPathComponent("Library/Preferences/com.kdt.livecontainer.plist").path)
    }

    static func containerIdentifier(_ container: URL) -> String? {
        let plist = container.appendingPathComponent("LCContainerInfo.plist")
        if let v = try? plist.resourceValues(forKeys: [.isSymbolicLinkKey]), v.isSymbolicLink == true {
            return nil
        }
        guard let data = try? Data(contentsOf: plist),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = raw as? [String: Any],
              let ident = dict["appIdentifier"] as? String,
              !ident.isEmpty else { return nil }
        return ident
    }

    static func isDirectory(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return v.isSymbolicLink != true && v.isDirectory == true
    }
}

// MARK: - 清单与结果

struct CleanItem: Identifiable, Sendable {
    let category: CleanCategory
    let appName: String
    let bundleID: String
    let containerName: String
    let url: URL
    let displayPath: String
    let bytes: Int64
    let note: String
    let isDirectory: Bool
    let minAgeHours: Double
    let inSharedTmp: Bool
    let containerRoot: URL?

    var id: String { url.standardizedFileURL.path }

    // 共享临时区里判不出归属的 .tmp：列出来，但默认不勾，必须由人确认。
    var needsConfirm: Bool {
        inSharedTmp && appName.hasPrefix("共享临时区（所有 app 共用）")
    }
}

struct ScanResult: Sendable {
    var items: [CleanItem] = []
    var notes: [String] = []

    var totalBytes: Int64 { items.reduce(Int64(0)) { $0 + $1.bytes } }
}

struct DeleteOutcome: Sendable {
    var deleted = 0
    var failed = 0
    var skipped = 0
    var freed: Int64 = 0
    var lines: [String] = []
    var fresh = ScanResult()
}

// MARK: - 扫描 / 删除

final class Cleaner {
    let env: CleanerEnv
    private let fm = FileManager.default

    // 这些名字哪怕规则算错了也不许删。
    private static let protectedNames: Set<String> = [
        "LCContainerInfo.plist", "LCAppInfo.plist",
        "Data", "Application", "Applications", "Documents", "Library", "Caches", "tmp",
        "compiled", "nights", "snippets",
        "swap_models", "swap_idents", "voice_models", "samples",
        "version.txt", "chain.txt", "archive.part",
        "fsx_arc.mlpackage", "fsx_swap.mlpackage",
    ]

    private static let logNames: [String: [String]] = [
        "com.qoder.hellolc": ["hello_log.txt"],
        "com.qoder.liveswap": ["hello_log.txt"],
        "com.qoder.snorebench": ["snore_log.txt"],
        "com.qoder.swapbench": ["swap_log.txt", "swap_runs.txt"],
        "com.qoder.vr3d": ["vr_log.txt"],
        "com.qoder.voice": ["voice_log.txt"],
    ]

    private static let swapModels: Set<String> = ["fsx_arc.mlpackage", "fsx_swap.mlpackage"]
    private static let voiceHistoryPrefixes = ["pick_", "record_", "tts_raw_", "output_", "novel_", "video_"]

    init(env: CleanerEnv) {
        self.env = env
    }

    // MARK: 扫描

    func scan(categories: Set<CleanCategory>, historyDays: Int) -> ScanResult {
        var items: [CleanItem] = []
        var notes: [String] = []

        if categories.contains(.junk) {
            for target in env.targets {
                for container in target.containers {
                    items += scanLogs(target: target, container: container)
                    let containerTmp = scanContainerTmp(target: target, container: container)
                    items += containerTmp.items
                    notes += containerTmp.notes
                    let loose = scanLooseTmp(target: target, container: container)
                    items += loose.items
                    notes += loose.notes
                }
            }
            let shared = scanTmp()
            items += shared.items
            notes += shared.notes
        }

        if categories.contains(.model) {
            for target in env.targets {
                for container in target.containers {
                    let r = scanModels(target: target, container: container)
                    items += r.items
                    notes += r.notes
                }
            }
        }

        if categories.contains(.history) {
            let days = max(0, historyDays)
            for target in env.targets {
                for container in target.containers {
                    let r = scanHistory(target: target, container: container, days: days)
                    items += r.items
                    notes += r.notes
                }
            }
            let sharedVideos = scanSharedTmpVideos(days: days)
            items += sharedVideos.items
            notes += sharedVideos.notes
        }

        var seen = Set<String>()
        let uniqueItems = items.filter { seen.insert($0.id).inserted }
        var seenNote = Set<String>()
        let uniqueNotes = notes.filter { seenNote.insert($0).inserted }
        let sorted = uniqueItems.sorted { a, b in
            let ra = categoryRank(a.category)
            let rb = categoryRank(b.category)
            if ra != rb { return ra < rb }
            if a.appName != b.appName { return a.appName < b.appName }
            if a.displayPath != b.displayPath { return a.displayPath < b.displayPath }
            return a.containerName < b.containerName
        }
        return ScanResult(items: sorted, notes: uniqueNotes)
    }

    private func categoryRank(_ c: CleanCategory) -> Int {
        switch c {
        case .junk: return 0
        case .model: return 1
        case .history: return 2
        }
    }

    private func scanLogs(target: CleanTarget, container: CleanContainer) -> [CleanItem] {
        guard let names = Self.logNames[target.bundleID] else { return [] }
        let docs = container.url.appendingPathComponent("Documents", isDirectory: true)
        var out: [CleanItem] = []
        for name in names {
            let url = docs.appendingPathComponent(name)
            if let item = containerItem(
                category: .junk,
                target: target,
                container: container,
                url: url,
                note: "运行日志（也是闪退证据，确认不要了再删）",
                minAgeHours: 1
            ) {
                out.append(item)
            }
        }
        return out
    }

    private struct TmpRule {
        let token: String
        let exact: Bool
        let bundleID: String
        let appName: String
        let note: String
    }

    private static let tmpRules: [TmpRule] = [
        TmpRule(token: "swap_", exact: false, bundleID: "com.qoder.swapbench",
                appName: "换脸出片", note: "换脸出片／选片副本（共享临时区；出片前会先清上一轮）"),
        TmpRule(token: "vr3d_", exact: false, bundleID: "com.qoder.vr3d",
                appName: "VR3D", note: "选片副本／深度缓存残留"),
        TmpRule(token: "pick_", exact: false, bundleID: "",
                appName: "剪辑 / 语音 / 直播共用", note: "选文件时拷进临时区的副本"),
        TmpRule(token: "cut_", exact: false, bundleID: "com.qoder.hellolc",
                appName: "剪辑", note: "剪辑中间文件"),
        TmpRule(token: "LiveIn", exact: true, bundleID: "com.qoder.liveswap",
                appName: "直播", note: "直播收件目录（上次没清掉）"),
    ]

    // 递归找散落的 .tmp 时不进这些目录：要么是用户数据，要么是模型包内部。
    private static let looseTmpSkip: Set<String> = [
        "voice_models", "swap_idents", "samples", "nights",
    ]

    private static let forbiddenTmpTokens = [
        "livecontainer", "sidestore", "altstore", "com.kdt", "com.rileytestut",
    ]

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "mts", "m2ts", "ts",
    ]

    // 递归找视频时不进：用户数据／模型包／系统目录／LC 的共享 app group 和收件箱。
    private static let videoSkipDirs: Set<String> = [
        "voice_models", "swap_idents", "samples", "nights",
        "Cookies", "Cookies2", "Preferences", "SystemData",
        "LCAppGroup", "Inbox",
    ]

    private static func isTmpName(_ name: String) -> Bool {
        name.count > 4 && name.lowercased().hasSuffix(".tmp")
    }

    private static func isVideoName(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func isForbiddenTmpName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return forbiddenTmpTokens.contains { lower.contains($0) }
    }

    // 共享临时区 = LC 进程的 TMPDIR，所有客人 app 的 tmp 符号链接都指到这里。
    private func scanTmp() -> RuleResult {
        var out = RuleResult()
        let entries = (try? fm.contentsOfDirectory(
            at: env.tmpDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        )) ?? []
        var genericTmp = 0
        var genericVideo = 0
        for url in entries {
            let name = url.lastPathComponent
            if let rule = Self.tmpRules.first(where: {
                $0.exact ? name == $0.token : name.hasPrefix($0.token)
            }) {
                if let item = tmpItem(rule: rule, url: url) { out.items.append(item) }
                continue
            }
            // 剩下的只认顶层普通文件（.tmp 或视频）；目录和符号链接一律不碰。
            guard let f = facts(url), !f.isSymbolicLink, !f.isDirectory,
                  !Self.isForbiddenTmpName(name) else { continue }
            if Self.isTmpName(name) {
                if let item = sharedTmpItem(url: url, facts: f) {
                    out.items.append(item)
                    genericTmp += 1
                }
            } else if Self.isVideoName(name) {
                if let item = sharedTmpVideoItem(url: url, facts: f) {
                    out.items.append(item)
                    genericVideo += 1
                }
            }
        }
        if genericTmp > 0 {
            out.notes.append("共享临时区里有 \(genericTmp) 个 6 小时没改动的 .tmp 文件：所有 app 共用，判不出归属，默认不勾选；确认是本机 app 留下的再手动选上")
        }
        if genericVideo > 0 {
            out.notes.append("共享临时区里有 \(genericVideo) 个 6 小时没改动的视频文件：判不出归属，默认不勾选；换脸成片通常以 swap_ 开头，会按换脸出片列出")
        }
        return out
    }

    private func sharedTmpItem(url: URL, facts f: FileFacts) -> CleanItem? {
        guard !f.isDirectory, let base = f.modified,
              Date().timeIntervalSince(base) >= 6 * 3600 else { return nil }
        return CleanItem(
            category: .junk,
            appName: "共享临时区（所有 app 共用）",
            bundleID: "",
            containerName: "共享临时区",
            url: url,
            displayPath: "临时区/\(url.lastPathComponent)",
            bytes: f.bytes,
            note: "中断的下载／导出留下的 .tmp（6 小时没改动）",
            isDirectory: false,
            minAgeHours: 6,
            inSharedTmp: true,
            containerRoot: nil
        )
    }

    private func sharedTmpVideoItem(url: URL, facts f: FileFacts) -> CleanItem? {
        guard !f.isDirectory, let base = f.modified,
              Date().timeIntervalSince(base) >= 6 * 3600 else { return nil }
        return CleanItem(
            category: .junk,
            appName: "共享临时区（所有 app 共用）",
            bundleID: "",
            containerName: "共享临时区",
            url: url,
            displayPath: "临时区/\(url.lastPathComponent)",
            bytes: f.bytes,
            note: "共享临时区里的视频文件（6 小时没改动，判不出归属）",
            isDirectory: false,
            minAgeHours: 6,
            inSharedTmp: true,
            containerRoot: nil
        )
    }

    // LC 启动时把 <容器>/tmp 做成指向共享 TMPDIR 的符号链接；跟着扫会和共享临时区重复，
    // 所以只扫真实目录（有些 app 会把符号链接删掉、自己建一个）。
    private func scanContainerTmp(target: CleanTarget, container: CleanContainer) -> RuleResult {
        var out = RuleResult()
        let tmp = container.url.appendingPathComponent("tmp", isDirectory: true)
        guard let tf = facts(tmp), !tf.isSymbolicLink, tf.isDirectory else { return out }
        let entries = (try? fm.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        )) ?? []
        for url in entries {
            guard let ef = facts(url), !ef.isSymbolicLink else { continue }
            let ageBase = ef.isDirectory ? newestModification(url) : nil
            if let item = containerItem(
                category: .junk, target: target, container: container, url: url,
                note: "容器真实 tmp 目录里的残留（不是共享临时区的符号链接）",
                minAgeHours: 6, ageBase: ageBase
            ) {
                out.items.append(item)
            }
        }
        if !out.items.isEmpty {
            out.notes.append("「\(target.name)」的容器里有一个真实 tmp 目录，列了 \(out.items.count) 项 6 小时没改动的残留")
        }
        return out
    }

    // Documents / Library/Caches 里散落的 .tmp：只认普通文件，不进模型包、nights、voice_models 这些用户数据目录。
    private func scanLooseTmp(target: CleanTarget, container: CleanContainer) -> RuleResult {
        var out = RuleResult()
        let bases = [
            container.url.appendingPathComponent("Documents", isDirectory: true),
            container.url.appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true),
        ]
        for base in bases where CleanerDiscovery.isDirectory(base) {
            for url in findTmpFiles(in: base) {
                if let item = containerItem(
                    category: .junk, target: target, container: container, url: url,
                    note: "中断的下载／导出留下的 .tmp（6 小时没改动）", minAgeHours: 6
                ) {
                    out.items.append(item)
                }
            }
        }
        if !out.items.isEmpty {
            out.notes.append("「\(target.name)」的 Documents / Library/Caches 里有 \(out.items.count) 个 .tmp 残留（只删文件；模型包和用户数据目录不进去）")
        }
        return out
    }

    private func findTmpFiles(in base: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        guard let e = fm.enumerator(
            at: base,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            if v.isSymbolicLink == true {
                e.skipDescendants()
                continue
            }
            if v.isDirectory == true {
                let name = u.lastPathComponent
                if Self.looseTmpSkip.contains(name)
                    || name.hasSuffix(".mlpackage")
                    || name.hasSuffix(".mlmodelc") {
                    e.skipDescendants()
                }
                continue
            }
            if v.isRegularFile == true, Self.isTmpName(u.lastPathComponent) {
                out.append(u)
            }
        }
        return out
    }

    private func tmpItem(rule: TmpRule, url: URL) -> CleanItem? {
        guard let f = facts(url), !f.isSymbolicLink else { return nil }
        let base = f.isDirectory ? newestModification(url) : f.modified
        guard let base, Date().timeIntervalSince(base) >= 6 * 3600 else { return nil }
        let bytes = f.isDirectory ? directorySize(url) : f.bytes
        return CleanItem(
            category: .junk,
            appName: rule.appName,
            bundleID: rule.bundleID,
            containerName: "共享临时区",
            url: url,
            displayPath: "临时区/\(url.lastPathComponent)",
            bytes: bytes,
            note: rule.note,
            isDirectory: f.isDirectory,
            minAgeHours: 6,
            inSharedTmp: true,
            containerRoot: nil
        )
    }

    private struct RuleResult {
        var items: [CleanItem] = []
        var notes: [String] = []
    }

    private func scanModels(target: CleanTarget, container: CleanContainer) -> RuleResult {
        switch target.bundleID {
        case "com.qoder.swapbench":
            return scanSwapModels(target: target, container: container)
        case "com.qoder.vr3d":
            return scanVRModels(target: target, container: container)
        case "com.qoder.voice":
            return scanVoiceModels(container: container)
        default:
            return RuleResult()
        }
    }

    private func scanSwapModels(target: CleanTarget, container: CleanContainer) -> RuleResult {
        var out = RuleResult()
        let docs = container.url.appendingPathComponent("Documents", isDirectory: true)
        let models = docs.appendingPathComponent("swap_models", isDirectory: true)

        let entries = (try? fm.contentsOfDirectory(
            at: models,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )) ?? []
        for url in entries {
            guard let f = facts(url), !f.isSymbolicLink else { continue }
            let name = url.lastPathComponent
            if name.hasSuffix(".mlpackage") && !Self.swapModels.contains(name) {
                if let item = containerItem(
                    category: .model, target: target, container: container, url: url,
                    note: "旧模型包（当前只认 fsx_arc / fsx_swap）", minAgeHours: 1
                ) { out.items.append(item) }
            } else if name == "emap.bin" {
                if let item = containerItem(
                    category: .model, target: target, container: container, url: url,
                    note: "旧人脸底图（现在的链路不用它）", minAgeHours: 1
                ) { out.items.append(item) }
            }
        }

        for name in Self.swapModels.sorted() where !fm.fileExists(atPath: models.appendingPathComponent(name).path) {
            out.notes.append("当前换脸模型缺 \(name)：app 启动时会去补下载；助手不会碰下载中的 archive.part")
        }
        out.notes.append("换脸模型保留 fsx_arc / fsx_swap、version.txt、chain.txt、archive.part（archive.part 是没下完的那份，删了要从头下）")

        let compiledRoot = container.url
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("compiled", isDirectory: true)
        if CleanerDiscovery.isDirectory(compiledRoot) {
            let versionURL = models.appendingPathComponent("version.txt")
            let versionText = (try? Data(contentsOf: versionURL))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let version = versionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if version.isEmpty {
                out.notes.append("读不出 swap_models/version.txt，编译缓存这次一个都不列（怕删到正在用的那版）")
            } else {
                let dirs = (try? fm.contentsOfDirectory(
                    at: compiledRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                    options: []
                )) ?? []
                for url in dirs {
                    guard let f = facts(url), !f.isSymbolicLink, f.isDirectory else { continue }
                    if url.lastPathComponent == version { continue }
                    if let item = containerItem(
                        category: .model, target: target, container: container, url: url,
                        note: "旧版本编译缓存（当前 version.txt = \(version)）", minAgeHours: 1
                    ) { out.items.append(item) }
                }
                out.notes.append("编译缓存保留当前版本 \(version)")
            }
        }
        return out
    }

    private func scanVRModels(target: CleanTarget, container: CleanContainer) -> RuleResult {
        var out = RuleResult()
        let docs = container.url.appendingPathComponent("Documents", isDirectory: true)
        let entries = (try? fm.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )) ?? []
        for url in entries {
            guard let f = facts(url), !f.isSymbolicLink, !f.isDirectory else { continue }
            let name = url.lastPathComponent
            guard name.hasPrefix("vr3d_depth_"), name.hasSuffix(".bin") else { continue }
            if let item = containerItem(
                category: .model, target: target, container: container, url: url,
                note: "深度缓存残留（正常跑完会自己删）", minAgeHours: 1
            ) { out.items.append(item) }
        }
        return out
    }

    private func scanVoiceModels(container: CleanContainer) -> RuleResult {
        var out = RuleResult()
        let models = container.url
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("voice_models", isDirectory: true)
        if CleanerDiscovery.isDirectory(models) {
            out.notes.append("语音模型目录保留（\(CleanFormat.bytes(directorySize(models)))）：删了下次要重新下约 581 MB")
        } else {
            out.notes.append("没找到 Documents/voice_models：助手不下载、也不删除语音模型")
        }
        return out
    }

    private func scanHistory(target: CleanTarget, container: CleanContainer, days: Int) -> RuleResult {
        var out = RuleResult()
        let minHours = Double(days) * 24
        let cutoff = Date().addingTimeInterval(-minHours * 3600)
        let docs = container.url.appendingPathComponent("Documents", isDirectory: true)

        switch target.bundleID {
        case "com.qoder.hellolc":
            for url in rootFiles(docs, matching: { $0.hasPrefix("cut_") && $0.hasSuffix(".mov") }) {
                if let item = containerItem(
                    category: .history, target: target, container: container, url: url,
                    note: "旧成片（.mov，\(days) 天前）", minAgeHours: minHours
                ) { out.items.append(item) }
            }

        case "com.qoder.vr3d":
            for url in rootFiles(docs, matching: { $0.hasPrefix("vr3d_") && $0.hasSuffix(".mp4") }) {
                if let item = containerItem(
                    category: .history, target: target, container: container, url: url,
                    note: "旧成片（.mp4，\(days) 天前）", minAgeHours: minHours
                ) { out.items.append(item) }
            }

        case "com.qoder.voice":
            for url in rootFiles(docs, matching: { name in
                Self.voiceHistoryPrefixes.contains { name.hasPrefix($0) }
            }) {
                let kind = Self.voiceKind(url.lastPathComponent) ?? "历史文件"
                if let item = containerItem(
                    category: .history, target: target, container: container, url: url,
                    note: "\(kind)，\(days) 天前", minAgeHours: minHours
                ) { out.items.append(item) }
            }
            out.notes.append("语音历史只扫 Documents 根目录；samples 音色样本和 voice_models 不动")

        case "com.qoder.snorebench":
            let nights = docs.appendingPathComponent("nights", isDirectory: true)
            guard CleanerDiscovery.isDirectory(nights) else { break }
            let dirs = ((try? fm.contentsOfDirectory(
                at: nights,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []).filter {
                guard let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return v.isSymbolicLink != true && v.isDirectory == true
            }.sorted { $0.lastPathComponent > $1.lastPathComponent }

            let keepNewest = 3
            for (idx, dir) in dirs.enumerated() {
                if idx < keepNewest { continue }
                let name = dir.lastPathComponent
                guard let meta = readSnoreMeta(dir) else {
                    out.notes.append("鼾声：\(name) 的 meta.json 读不出来，这一晚没列入")
                    continue
                }
                guard meta.start < cutoff else { continue }
                let tail = meta.ended ? "" : "；没收尾"
                let note = "旧的一晚：\(CleanFormat.date(meta.start)) 开始\(tail)"
                // 年龄闸门已经在 meta.start 上判过，这里不再用目录 mtime 重复卡一次。
                if let item = containerItem(
                    category: .history, target: target, container: container, url: dir,
                    note: note, minAgeHours: 0, ageBase: meta.start
                ) { out.items.append(item) }
            }
            out.notes.append("鼾声：无论多旧都保留最新 \(keepNewest) 晚；只列 meta.json 可读、开睡时间早于 \(days) 天的目录")

        default:
            break
        }

        // 不管 app 把成片写成什么名字、放在哪一层，只要是视频就列出来。
        let videos = scanHistoryVideos(target: target, container: container, days: days)
        out.items += videos.items
        out.notes += videos.notes
        return out
    }

    private func scanHistoryVideos(target: CleanTarget, container: CleanContainer, days: Int) -> RuleResult {
        var out = RuleResult()
        let minHours = Double(days) * 24
        let note = days == 0 ? "视频文件（不限天数）" : "视频文件（\(days) 天前）"
        for url in findVideoFiles(in: container.url) {
            if let item = containerItem(
                category: .history, target: target, container: container, url: url,
                note: note, minAgeHours: minHours
            ) {
                out.items.append(item)
            }
        }
        if !out.items.isEmpty {
            out.notes.append("「\(target.name)」视频：列了 \(out.items.count) 个（含 Documents / Library / 真实 tmp 的子目录）")
        }
        return out
    }

    private func scanSharedTmpVideos(days: Int) -> RuleResult {
        var out = RuleResult()
        let minHours = Double(days) * 24
        let note = days == 0
            ? "共享临时区里的视频文件（不限天数，判不出归属）"
            : "共享临时区里的视频文件（\(days) 天没改动，判不出归属）"
        let entries = (try? fm.contentsOfDirectory(
            at: env.tmpDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        )) ?? []
        for url in entries {
            let name = url.lastPathComponent
            guard let f = facts(url), !f.isSymbolicLink, !f.isDirectory,
                  Self.isVideoName(name), !Self.isForbiddenTmpName(name),
                  let base = f.modified,
                  Date().timeIntervalSince(base) >= minHours * 3600 else { continue }
            out.items.append(CleanItem(
                category: .history,
                appName: "共享临时区（所有 app 共用）",
                bundleID: "",
                containerName: "共享临时区",
                url: url,
                displayPath: "临时区/\(name)",
                bytes: f.bytes,
                note: note,
                isDirectory: false,
                minAgeHours: minHours,
                inSharedTmp: true,
                containerRoot: nil
            ))
        }
        if !out.items.isEmpty {
            out.notes.append("共享临时区里的视频列了 \(out.items.count) 个，判不出归属，默认不勾选")
        }
        return out
    }

    private func findVideoFiles(in base: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        guard let e = fm.enumerator(
            at: base,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            if v.isSymbolicLink == true {
                e.skipDescendants()
                continue
            }
            if v.isDirectory == true {
                let name = u.lastPathComponent
                if Self.videoSkipDirs.contains(name)
                    || name.hasSuffix(".mlpackage")
                    || name.hasSuffix(".mlmodelc") {
                    e.skipDescendants()
                }
                continue
            }
            if v.isRegularFile == true, Self.isVideoName(u.lastPathComponent) {
                out.append(u)
            }
        }
        return out
    }

    private static func voiceKind(_ name: String) -> String? {
        if name.hasPrefix("pick_") || name.hasPrefix("record_") { return "源文件（选进来／录的）" }
        if name.hasPrefix("tts_raw_") { return "中间音频（系统原声）" }
        if name.hasPrefix("output_") || name.hasPrefix("novel_") { return "合成成品" }
        if name.hasPrefix("video_") { return "视频成品／中间文件" }
        return nil
    }

    private func rootFiles(_ docs: URL, matching: (String) -> Bool) -> [URL] {
        let entries = (try? fm.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )) ?? []
        var out: [URL] = []
        for url in entries {
            guard let f = facts(url), !f.isSymbolicLink, !f.isDirectory else { continue }
            if matching(url.lastPathComponent) { out.append(url) }
        }
        return out
    }

    private struct SnoreMetaLite {
        let start: Date
        let ended: Bool
    }

    private func readSnoreMeta(_ dir: URL) -> SnoreMetaLite? {
        let url = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any],
              let ms = obj["startMs"] as? Double else { return nil }
        let ended = (obj["ended"] as? Bool) ?? false
        return SnoreMetaLite(start: Date(timeIntervalSince1970: ms / 1000.0), ended: ended)
    }

    // MARK: 删除

    func delete(items chosen: [CleanItem], categories: Set<CleanCategory>, historyDays: Int) -> DeleteOutcome {
        var outcome = DeleteOutcome()
        // 先按同一套规则重扫：只有这一秒仍然在清单里的路径才允许删，扫描后新建/改过的自然被挡掉。
        let fresh = scan(categories: categories, historyDays: historyDays)
        var byKey: [String: CleanItem] = [:]
        for item in fresh.items { byKey[item.id] = item }

        for old in chosen {
            guard let item = byKey[old.id] else {
                outcome.skipped += 1
                outcome.lines.append("跳过（重新扫描时已不在清单）：\(old.displayPath)")
                continue
            }
            if let reason = unsafeReason(item) {
                outcome.failed += 1
                outcome.lines.append("拒绝（安全复核没过：\(reason)）：\(item.appName)｜\(item.displayPath)")
                continue
            }
            do {
                try fm.removeItem(at: item.url)
                outcome.deleted += 1
                outcome.freed += item.bytes
                outcome.lines.append("已删 \(item.appName)｜\(item.displayPath)｜\(CleanFormat.bytes(item.bytes))")
            } catch {
                outcome.failed += 1
                outcome.lines.append("失败 \(item.appName)｜\(item.displayPath)：\(error.localizedDescription)")
            }
        }

        outcome.fresh = scan(categories: categories, historyDays: historyDays)
        return outcome
    }

    private func unsafeReason(_ item: CleanItem) -> String? {
        let url = item.url
        let path = url.standardizedFileURL.path

        if path.contains("/Documents/Applications/") { return "位于 Applications 目录" }
        if !item.bundleID.isEmpty {
            guard CleanerDiscovery.isAllowed(item.bundleID) else { return "包名不在白名单" }
            guard !CleanerDiscovery.isForbidden(item.bundleID) else { return "LiveContainer / SideStore 禁止清理" }
        }

        if item.inSharedTmp {
            guard isInside(url, env.tmpDir) else { return "不在共享临时区里" }
        } else {
            guard let root = item.containerRoot else { return "没有容器身份" }
            guard isInside(url, root) else { return "不在容器里" }
            guard CleanerDiscovery.containerIdentifier(root) == item.bundleID else {
                return "容器的 LCContainerInfo.plist 与扫描时不符"
            }
            let known = env.targets.contains { target in
                target.bundleID == item.bundleID
                    && target.containers.contains { $0.url.standardizedFileURL.path == root.standardizedFileURL.path }
            }
            guard known else { return "容器不在这次发现的白名单里" }
        }

        guard !Self.protectedNames.contains(url.lastPathComponent) else { return "受保护的名字" }
        guard let f = facts(url), !f.isSymbolicLink else { return "文件不在了或是符号链接" }

        if item.minAgeHours > 0 {
            let base = f.isDirectory ? newestModification(url) : f.modified
            guard let base, Date().timeIntervalSince(base) >= item.minAgeHours * 3600 else {
                return "刚改过，可能还在写"
            }
        }
        return nil
    }

    // MARK: 文件事实

    private struct FileFacts {
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let bytes: Int64
        let modified: Date?
    }

    private func facts(_ url: URL) -> FileFacts? {
        guard let v = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
        ]) else { return nil }
        return FileFacts(
            isDirectory: v.isDirectory ?? false,
            isSymbolicLink: v.isSymbolicLink ?? false,
            bytes: Int64(v.fileSize ?? 0),
            modified: v.contentModificationDate
        )
    }

    private func containerItem(
        category: CleanCategory,
        target: CleanTarget,
        container: CleanContainer,
        url: URL,
        note: String,
        minAgeHours: Double,
        ageBase: Date? = nil
    ) -> CleanItem? {
        guard let f = facts(url), !f.isSymbolicLink else { return nil }
        let base = ageBase ?? f.modified
        guard let base, Date().timeIntervalSince(base) >= minAgeHours * 3600 else { return nil }
        let bytes = f.isDirectory ? directorySize(url) : f.bytes
        return CleanItem(
            category: category,
            appName: target.name,
            bundleID: target.bundleID,
            containerName: container.name,
            url: url,
            displayPath: displayPath(url, container: container),
            bytes: bytes,
            note: note,
            isDirectory: f.isDirectory,
            minAgeHours: minAgeHours,
            inSharedTmp: false,
            containerRoot: container.url
        )
    }

    private func displayPath(_ url: URL, container: CleanContainer) -> String {
        let base = container.url.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        let rel: String
        if p.hasPrefix(base + "/") {
            rel = String(p.dropFirst(base.count + 1))
        } else {
            rel = url.lastPathComponent
        }
        return "[\(String(container.name.prefix(8)))] \(rel)"
    }

    private func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let e = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    private func newestModification(_ url: URL) -> Date? {
        var newest = facts(url)?.modified
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isSymbolicLinkKey]
        guard let e = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return newest }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys),
                  v.isSymbolicLink != true,
                  let d = v.contentModificationDate else { continue }
            if newest == nil || d > newest! { newest = d }
        }
        return newest
    }

    private func isInside(_ child: URL, _ root: URL) -> Bool {
        let c = child.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        if c == r { return false }
        let prefix = r.hasSuffix("/") ? r : r + "/"
        return c.hasPrefix(prefix)
    }
}

// MARK: - 发到电脑 / 取回结论
//
// 只发路径和元数据，不发文件内容；电脑回的结论只做标记，app 不会照着自动删。
// 电脑上先跑 tools/report_server_cleaner.py（8718），手机和电脑在同一 Wi-Fi。

struct CleanerReportItem: Encodable {
    let path: String
    let app: String
    let bundleID: String
    let container: String
    let displayPath: String
    let category: String
    let bytes: Int64
    let modifiedAt: String
    let isDirectory: Bool
    let inSharedTmp: Bool
    let needsConfirm: Bool
    let note: String
}

struct CleanerReport: Encodable {
    let kind = "cleaner-scan"
    let schema = 1
    let generatedAt: String
    let categories: [String]
    let historyDays: Int
    let lcHome: String
    let notes: [String]
    let items: [CleanerReportItem]
}

enum CleanerReportBuilder {
    static func make(
        items: [CleanItem],
        notes: [String],
        categories: Set<CleanCategory>,
        historyDays: Int,
        lcHome: String?
    ) -> String {
        let fmt = ISO8601DateFormatter()
        let rows = items.map { item -> CleanerReportItem in
            let modified = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return CleanerReportItem(
                path: item.url.standardizedFileURL.path,
                app: item.appName,
                bundleID: item.bundleID,
                container: item.containerName,
                displayPath: item.displayPath,
                category: item.category.rawValue,
                bytes: item.bytes,
                modifiedAt: modified.map { fmt.string(from: $0) } ?? "",
                isDirectory: item.isDirectory,
                inSharedTmp: item.inSharedTmp,
                needsConfirm: item.needsConfirm,
                note: item.note
            )
        }
        let report = CleanerReport(
            generatedAt: fmt.string(from: Date()),
            categories: CleanCategory.allCases.filter { categories.contains($0) }.map(\.rawValue),
            historyDays: historyDays,
            lcHome: lcHome ?? "",
            notes: notes,
            items: rows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

enum CleanVerdictKind: String {
    case keep
    case delete
    case unsure

    var title: String {
        switch self {
        case .keep: return "保留"
        case .delete: return "可删"
        case .unsure: return "待定"
        }
    }
}

struct CleanerVerdictEntry: Decodable {
    let path: String
    let verdict: String
    let reason: String?

    var kind: CleanVerdictKind {
        CleanVerdictKind(rawValue: verdict.lowercased()) ?? .unsure
    }
}

struct CleanerVerdictFile: Decodable {
    let generatedAt: String?
    let items: [CleanerVerdictEntry]
}

struct CleanerVerdictMap {
    private(set) var byPath: [String: CleanerVerdictEntry]

    init(file: CleanerVerdictFile) {
        var map: [String: CleanerVerdictEntry] = [:]
        for entry in file.items where !entry.path.isEmpty {
            map[Self.normalize(entry.path)] = entry
        }
        byPath = map
    }

    init() {
        byPath = [:]
    }

    subscript(path: String) -> CleanerVerdictEntry? {
        byPath[Self.normalize(path)]
    }

    var isEmpty: Bool { byPath.isEmpty }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum CleanerPC {
    /// 8712 剪辑 / 8714 VR3D / 8715 Voice / 8716 换脸 / 8717 鼾声，这条线走 8718 和自己的接收文件。
    static let reportEndpoint = "http://192.168.31.99:8718/report"
    static let verdictEndpoint = "http://192.168.31.99:8718/verdict"

    static func sendReport(_ text: String) -> String {
        guard let url = URL(string: reportEndpoint) else { return "发到电脑：地址非法" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = text.data(using: .utf8)

        let done = DispatchSemaphore(value: 0)
        var code = -1
        var reply = ""
        var failure = ""
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { failure = "\(error)" }
            if let response = response as? HTTPURLResponse { code = response.statusCode }
            if let data = data { reply = String(data: data, encoding: .utf8) ?? "?" }
            done.signal()
        }.resume()

        if done.wait(timeout: .now() + 20) == .timedOut {
            return "发到电脑：超时 20 s 没回音（手机到 192.168.31.99:8718 不通？电脑上的 8718 接收端没开？）"
        }
        if code < 0 { return "发到电脑：失败 \(failure)" }
        return "发到电脑：HTTP \(code) 回执 \(reply)（送出 \(text.count) 字符）"
    }

    static func fetchVerdict() -> (message: String, verdict: CleanerVerdictFile?) {
        guard let url = URL(string: verdictEndpoint) else { return ("取回结论：地址非法", nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let done = DispatchSemaphore(value: 0)
        var code = -1
        var data: Data?
        var failure = ""
        URLSession.shared.dataTask(with: request) { body, response, error in
            if let error = error { failure = "\(error)" }
            if let response = response as? HTTPURLResponse { code = response.statusCode }
            data = body
            done.signal()
        }.resume()

        if done.wait(timeout: .now() + 20) == .timedOut {
            return ("取回结论：超时 20 s 没回音（电脑上的 8718 接收端没开？）", nil)
        }
        if code < 0 { return ("取回结论：失败 \(failure)", nil) }
        guard code == 200, let body = data else {
            return ("取回结论：HTTP \(code)", nil)
        }
        guard let file = try? JSONDecoder().decode(CleanerVerdictFile.self, from: body) else {
            return ("取回结论：电脑回的不是结论文件（HTTP \(code)）", nil)
        }
        if file.items.isEmpty {
            return ("取回结论：电脑上还没有结论（先把清单「发到电脑」）", file)
        }
        return ("取回结论：\(file.items.count) 条（\(file.generatedAt ?? "未写时间")）", file)
    }
}
