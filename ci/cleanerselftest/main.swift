import Darwin
import Foundation

// 假 LiveContainer 目录里跑一遍：只认白名单容器、只删规则命中的东西，
// LiveContainer / SideStore / 无 plist 的容器、符号链接、当前模型、archive.part 都必须原样保留。
// 判据只看这里的 CASE 和最后一行的 VERDICT；造不出来的夹具直接判 FAIL，不让它悄悄跳过。

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("cleaner-selftest-\(getpid())", isDirectory: true)
try? fm.removeItem(at: root)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok {
        print("CASE PASS \(what)")
    } else {
        failures += 1
        print("CASE FAIL \(what)")
    }
}

func makeDir(_ url: URL) {
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
}

func writeText(_ text: String, to url: URL) {
    makeDir(url.deletingLastPathComponent())
    try? Data(text.utf8).write(to: url)
}

func writePlist(_ dict: [String: Any], to url: URL) {
    makeDir(url.deletingLastPathComponent())
    guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
        check(false, "写 plist \(url.lastPathComponent)")
        return
    }
    try? data.write(to: url)
}

func makeOld(_ url: URL, hours: Double) {
    try? fm.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-hours * 3600)],
        ofItemAtPath: url.path
    )
}

func exists(_ url: URL) -> Bool {
    fm.fileExists(atPath: url.path)
}

// MARK: 夹具

let home = root.appendingPathComponent("home", isDirectory: true)
let dataRoot = home.appendingPathComponent("Documents/Data/Application", isDirectory: true)
makeDir(dataRoot)

let swap = dataRoot.appendingPathComponent("11111111-AAAA", isDirectory: true)
let hello = dataRoot.appendingPathComponent("22222222-BBBB", isDirectory: true)
let snore = dataRoot.appendingPathComponent("33333333-CCCC", isDirectory: true)
let liveContainer = dataRoot.appendingPathComponent("44444444-LCLC", isDirectory: true)
let sideStore = dataRoot.appendingPathComponent("55555555-SIDE", isDirectory: true)
let orphan = dataRoot.appendingPathComponent("66666666-NONE", isDirectory: true)

writePlist(["appIdentifier": "com.qoder.swapbench"], to: swap.appendingPathComponent("LCContainerInfo.plist"))
writePlist(["appIdentifier": "com.qoder.hellolc"], to: hello.appendingPathComponent("LCContainerInfo.plist"))
writePlist(["appIdentifier": "com.qoder.snorebench"], to: snore.appendingPathComponent("LCContainerInfo.plist"))
writePlist(["appIdentifier": "com.kdt.livecontainer"], to: liveContainer.appendingPathComponent("LCContainerInfo.plist"))
writePlist(["appIdentifier": "com.SideStore.SideStore.TEAM"], to: sideStore.appendingPathComponent("LCContainerInfo.plist"))
makeDir(orphan.appendingPathComponent("Documents", isDirectory: true))
writeText("orphan junk", to: orphan.appendingPathComponent("Documents/swap_runs.txt"))
makeOld(orphan.appendingPathComponent("Documents/swap_runs.txt"), hours: 10)

// —— 换脸：日志、旧模型、编译缓存、当前模型、没下完的 archive.part
let swapDocs = swap.appendingPathComponent("Documents", isDirectory: true)
writeText("log", to: swapDocs.appendingPathComponent("swap_runs.txt"))
makeOld(swapDocs.appendingPathComponent("swap_runs.txt"), hours: 10)

let external = root.appendingPathComponent("outside-hosts-sim.txt")
writeText("do not touch", to: external)
makeOld(external, hours: 10)
let link = swapDocs.appendingPathComponent("swap_log.txt")
var linkOK = false
do {
    try fm.createSymbolicLink(at: link, withDestinationURL: external)
    linkOK = true
} catch {
    linkOK = false
}
check(linkOK, "夹具：swap_log.txt 做成符号链接")

let models = swapDocs.appendingPathComponent("swap_models", isDirectory: true)
let currentArc = models.appendingPathComponent("fsx_arc.mlpackage", isDirectory: true)
let currentSwap = models.appendingPathComponent("fsx_swap.mlpackage", isDirectory: true)
let oldModel = models.appendingPathComponent("old_face.mlpackage", isDirectory: true)
makeDir(currentArc)
makeDir(currentSwap)
makeDir(oldModel)
writeText("model", to: currentArc.appendingPathComponent("Data/model.bin"))
writeText("model", to: currentSwap.appendingPathComponent("Data/model.bin"))
writeText("model", to: oldModel.appendingPathComponent("Data/model.bin"))
writeText("7.2", to: models.appendingPathComponent("version.txt"))
writeText("chain", to: models.appendingPathComponent("chain.txt"))
writeText("partial", to: models.appendingPathComponent("archive.part"))
writeText("emap", to: models.appendingPathComponent("emap.bin"))
makeDir(swapDocs.appendingPathComponent("swap_idents", isDirectory: true))
writeText("ident", to: swapDocs.appendingPathComponent("swap_idents/abc.pak"))

let compiled = swap.appendingPathComponent("Library/Caches/compiled", isDirectory: true)
let compiledCurrent = compiled.appendingPathComponent("7.2", isDirectory: true)
let compiledOld = compiled.appendingPathComponent("6.0", isDirectory: true)
makeDir(compiledCurrent)
makeDir(compiledOld)
writeText("mlmodelc", to: compiledCurrent.appendingPathComponent("fsx_arc.mlmodelc/model.bin"))
writeText("mlmodelc", to: compiledOld.appendingPathComponent("fsx_arc.mlmodelc/model.bin"))

// 当前模型也做旧：证明“没删”靠的是名字/版本，不是因为太新才被留下。
for u in [currentArc, currentSwap, models.appendingPathComponent("version.txt"),
          models.appendingPathComponent("chain.txt"), models.appendingPathComponent("archive.part"),
          swapDocs.appendingPathComponent("swap_idents"), swapDocs.appendingPathComponent("swap_idents/abc.pak"),
          compiledCurrent, compiledCurrent.appendingPathComponent("fsx_arc.mlmodelc")] {
    makeOld(u, hours: 12)
}
for u in [oldModel, oldModel.appendingPathComponent("Data"), oldModel.appendingPathComponent("Data/model.bin"),
          compiledOld, compiledOld.appendingPathComponent("fsx_arc.mlmodelc"),
          compiledOld.appendingPathComponent("fsx_arc.mlmodelc/model.bin"),
          models.appendingPathComponent("emap.bin")] {
    makeOld(u, hours: 12)
}

// —— 剪辑：旧成片按 30 天闸门；日志算垃圾
let helloDocs = hello.appendingPathComponent("Documents", isDirectory: true)
writeText("old", to: helloDocs.appendingPathComponent("cut_old.mov"))
writeText("new", to: helloDocs.appendingPathComponent("cut_new.mov"))
writeText("log", to: helloDocs.appendingPathComponent("hello_log.txt"))
makeOld(helloDocs.appendingPathComponent("cut_old.mov"), hours: 40 * 24)
makeOld(helloDocs.appendingPathComponent("cut_new.mov"), hours: 2 * 24)
makeOld(helloDocs.appendingPathComponent("hello_log.txt"), hours: 10)

// —— 鼾声：5 晚，最新 3 晚无论多旧都保留；最老那晚 valid，次老那晚 meta 坏掉
let nights = snore.appendingPathComponent("Documents/nights", isDirectory: true)
makeDir(nights)
let nightNames = ["20260101-000000", "20260102-000000", "20260103-000000", "20260104-000000", "20260105-000000"]
for (i, name) in nightNames.enumerated() {
    let dir = nights.appendingPathComponent(name, isDirectory: true)
    makeDir(dir.appendingPathComponent("snippets", isDirectory: true))
    writeText("t,db\n0,40\n", to: dir.appendingPathComponent("curve.csv"))
    writeText("{}", to: dir.appendingPathComponent("snippets/s_1.wav"))
    if name == "20260102-000000" {
        writeText("not json", to: dir.appendingPathComponent("meta.json"))
    } else {
        let start = Date().addingTimeInterval(-Double(40 - i) * 24 * 3600)
        let ms = start.timeIntervalSince1970 * 1000
        writeText(
            "{\"id\":\"\(name)\",\"startMs\":\(ms),\"endMs\":\(ms),\"ended\":true,\"sampleRate\":48000,"
                + "\"restarts\":0,\"blocks\":0,\"seconds\":60,\"device\":\"selftest\",\"note\":\"\"}",
            to: dir.appendingPathComponent("meta.json")
        )
    }
}
writeText("log", to: snore.appendingPathComponent("Documents/snore_log.txt"))
makeOld(snore.appendingPathComponent("Documents/snore_log.txt"), hours: 10)
makeOld(nights, hours: 50 * 24)

// —— LiveContainer / SideStore / 无 plist 容器里的同名垃圾：一个都不许进清单
writeText("lc log", to: liveContainer.appendingPathComponent("Documents/swap_runs.txt"))
writeText("side output", to: sideStore.appendingPathComponent("Documents/cut_old.mov"))
makeOld(liveContainer.appendingPathComponent("Documents/swap_runs.txt"), hours: 10)
makeOld(sideStore.appendingPathComponent("Documents/cut_old.mov"), hours: 40 * 24)

// —— 共享临时区：认前缀 + 通用 .tmp；6 小时内还在变的不动
let tmp = root.appendingPathComponent("tmp", isDirectory: true)
makeDir(tmp)
writeText("old", to: tmp.appendingPathComponent("swap_old.tmp"))
writeText("new", to: tmp.appendingPathComponent("swap_new.tmp"))
writeText("old", to: tmp.appendingPathComponent("cut_old.tmp"))
writeText("x", to: tmp.appendingPathComponent("not_ours.bin"))
makeDir(tmp.appendingPathComponent("LiveIn", isDirectory: true))
writeText("incoming", to: tmp.appendingPathComponent("LiveIn/incoming.mp4"))
makeOld(tmp.appendingPathComponent("swap_old.tmp"), hours: 10)
makeOld(tmp.appendingPathComponent("cut_old.tmp"), hours: 10)
makeOld(tmp.appendingPathComponent("not_ours.bin"), hours: 10)
makeOld(tmp.appendingPathComponent("LiveIn"), hours: 10)
makeOld(tmp.appendingPathComponent("LiveIn/incoming.mp4"), hours: 10)

// 共享临时区里的通用 .tmp：旧的中断下载要列，刚生成的、名字带 LC/SideStore 的不列
let staleDownload = tmp.appendingPathComponent("CFNetworkDownload_stale.tmp")
let freshDownload = tmp.appendingPathComponent("CFNetworkDownload_fresh.tmp")
let lcTmpFile = tmp.appendingPathComponent("com.kdt.livecontainer.tmp")
writeText("partial", to: staleDownload)
writeText("partial", to: freshDownload)
writeText("lc", to: lcTmpFile)
makeOld(staleDownload, hours: 10)
makeOld(lcTmpFile, hours: 10)

// —— 容器真实 tmp：LC 默认把它做成符号链接，app 删掉重建后才是真实目录
let swapTmp = swap.appendingPathComponent("tmp", isDirectory: true)
makeDir(swapTmp)
writeText("leftover", to: swapTmp.appendingPathComponent("leftover_export.tmp"))
writeText("frame", to: swapTmp.appendingPathComponent("frame_0001.bin"))
writeText("active", to: swapTmp.appendingPathComponent("active_export.tmp"))
makeOld(swapTmp.appendingPathComponent("leftover_export.tmp"), hours: 10)
makeOld(swapTmp.appendingPathComponent("frame_0001.bin"), hours: 10)

// —— 剪辑的 tmp 是符号链接（指向共享临时区）：只跳过，不能重复列
let helloTmpLink = hello.appendingPathComponent("tmp", isDirectory: true)
var helloLinkOK = false
do {
    try fm.createSymbolicLink(at: helloTmpLink, withDestinationURL: tmp)
    helloLinkOK = true
} catch {
    helloLinkOK = false
}
check(helloLinkOK, "夹具：剪辑 tmp 做成指向共享临时区的符号链接")

// —— Documents / Library/Caches 里散落的 .tmp
writeText("export", to: helloDocs.appendingPathComponent("cut_export.mov.tmp"))
writeText("fresh", to: helloDocs.appendingPathComponent("cut_export_fresh.mov.tmp"))
makeOld(helloDocs.appendingPathComponent("cut_export.mov.tmp"), hours: 10)
let swapCaches = swap.appendingPathComponent("Library/Caches", isDirectory: true)
makeDir(swapCaches)
writeText("download", to: swapCaches.appendingPathComponent("stale-download.tmp"))
makeOld(swapCaches.appendingPathComponent("stale-download.tmp"), hours: 10)

// —— 这些目录里的 .tmp 不该被扫：鼾声 nights、换脸模型包内部、编译缓存内部
let nightTmp = nights.appendingPathComponent("20260101-000000/meta.json.tmp")
writeText("tmp", to: nightTmp)
makeOld(nightTmp, hours: 10)
let modelTmp = currentArc.appendingPathComponent("Data/leftover.tmp")
writeText("tmp", to: modelTmp)
makeOld(modelTmp, hours: 10)
let compiledTmp = compiledCurrent.appendingPathComponent("fsx_arc.mlmodelc/partial.tmp")
writeText("tmp", to: compiledTmp)
makeOld(compiledTmp, hours: 10)

// MARK: 发现

let env = CleanerDiscovery.discover(homeHint: home, tmpDir: tmp)
check(env.insideLC, "发现：认得 LiveContainer 主目录")
let swapTarget = env.targets.first { $0.bundleID == "com.qoder.swapbench" }
let helloTarget = env.targets.first { $0.bundleID == "com.qoder.hellolc" }
check(swapTarget?.containers.count == 1, "发现：换脸只有一个容器")
check(helloTarget?.containers.count == 1, "发现：剪辑只有一个容器")
check(env.containerCount == 3, "发现：只认 3 个白名单容器（换脸/剪辑/鼾声）")
check(swapTarget?.containers.first?.appIdentifier == "com.qoder.swapbench", "发现：容器身份来自 LCContainerInfo.plist")
check(!env.targets.contains { $0.containers.contains { $0.appIdentifier == "com.kdt.livecontainer" } }, "发现：LiveContainer 不在目标里")
check(!env.targets.contains { $0.containers.contains { $0.appIdentifier.hasPrefix("com.SideStore") } }, "发现：SideStore 不在目标里")

// MARK: 扫描垃圾 + 模型

let cleaner = Cleaner(env: env)
let junkAndModel = cleaner.scan(categories: [.junk, .model], historyDays: 30)
let paths = Set(junkAndModel.items.map { $0.url.standardizedFileURL.path })
let names = Set(junkAndModel.items.map { $0.url.lastPathComponent })

check(paths.contains(swapDocs.appendingPathComponent("swap_runs.txt").path), "扫描：换脸日志在清单里")
check(paths.contains(helloDocs.appendingPathComponent("hello_log.txt").path), "扫描：剪辑日志在清单里")
check(paths.contains(snore.appendingPathComponent("Documents/snore_log.txt").path), "扫描：鼾声日志在清单里")
check(!paths.contains(swapDocs.appendingPathComponent("swap_log.txt").path), "扫描：符号链接 swap_log.txt 不进清单")
check(names.contains("old_face.mlpackage"), "扫描：旧 mlpackage 在清单里")
check(names.contains("emap.bin"), "扫描：emap.bin 在清单里")
check(paths.contains(compiledOld.path), "扫描：旧编译缓存 6.0 在清单里")
check(!names.contains("fsx_arc.mlpackage"), "扫描：当前 fsx_arc 不在清单里")
check(!names.contains("fsx_swap.mlpackage"), "扫描：当前 fsx_swap 不在清单里")
check(!names.contains("archive.part"), "扫描：archive.part 不在清单里")
check(!names.contains("version.txt"), "扫描：version.txt 不在清单里")
check(!paths.contains(compiledCurrent.path), "扫描：当前编译缓存 7.2 不在清单里")
check(!paths.contains(swapDocs.appendingPathComponent("swap_idents").path), "扫描：swap_idents 身份存档不在清单里")

check(paths.contains(tmp.appendingPathComponent("swap_old.tmp").path), "扫描：旧的 swap_ 临时文件在清单里")
check(paths.contains(tmp.appendingPathComponent("cut_old.tmp").path), "扫描：旧的 cut_ 临时文件在清单里")
check(paths.contains(tmp.appendingPathComponent("LiveIn").path), "扫描：旧的 LiveIn 目录在清单里")
check(!paths.contains(tmp.appendingPathComponent("swap_new.tmp").path), "扫描：6 小时内改过的 swap_ 文件不动")
check(!paths.contains(tmp.appendingPathComponent("not_ours.bin").path), "扫描：不认识的临时文件不列")

check(paths.contains(staleDownload.path), "扫描：共享临时区里旧的通用 .tmp 在清单里")
check(junkAndModel.items.first { $0.url.standardizedFileURL.path == staleDownload.path }?.needsConfirm == true, "扫描：判不出归属的共享 .tmp 默认不勾选")
check(junkAndModel.items.first { $0.url.standardizedFileURL.path == tmp.appendingPathComponent("swap_old.tmp").path }?.needsConfirm == false, "扫描：认识前缀的临时文件可默认勾选")
check(!paths.contains(freshDownload.path), "扫描：共享临时区里刚写的 .tmp 不动")
check(!paths.contains(lcTmpFile.path), "扫描：名字带 livecontainer 的 .tmp 不列")
check(paths.contains(swapTmp.appendingPathComponent("leftover_export.tmp").path), "扫描：容器真实 tmp 里的旧 .tmp 在清单里")
check(paths.contains(swapTmp.appendingPathComponent("frame_0001.bin").path), "扫描：容器真实 tmp 里的旧文件在清单里")
check(!paths.contains(swapTmp.appendingPathComponent("active_export.tmp").path), "扫描：容器真实 tmp 里刚写的文件不动")
check(!junkAndModel.items.contains { $0.url.path.hasPrefix(helloTmpLink.path + "/") }, "扫描：符号链接 tmp 只跳过、不跟随")
check(junkAndModel.items.filter { $0.url.lastPathComponent == "swap_old.tmp" }.count == 1, "扫描：共享 tmp 同一文件只列一次")
check(paths.contains(helloDocs.appendingPathComponent("cut_export.mov.tmp").path), "扫描：Documents 里旧的 .tmp 在清单里")
check(!paths.contains(helloDocs.appendingPathComponent("cut_export_fresh.mov.tmp").path), "扫描：Documents 里刚写的 .tmp 不动")
check(paths.contains(swapCaches.appendingPathComponent("stale-download.tmp").path), "扫描：Library/Caches 里旧的 .tmp 在清单里")
check(!paths.contains(nightTmp.path), "扫描：鼾声 nights 里的 .tmp 不列")
check(!paths.contains(modelTmp.path), "扫描：模型包内部的 .tmp 不列")
check(!paths.contains(compiledTmp.path), "扫描：编译缓存内部的 .tmp 不列")

check(!paths.contains(liveContainer.appendingPathComponent("Documents/swap_runs.txt").path), "扫描：LiveContainer 里的同名日志不进清单")
check(!paths.contains(sideStore.appendingPathComponent("Documents/cut_old.mov").path), "扫描：SideStore 里的文件不进清单")
check(!paths.contains(orphan.appendingPathComponent("Documents/swap_runs.txt").path), "扫描：没有 LCContainerInfo.plist 的容器不进清单")
check(junkAndModel.items.allSatisfy { !$0.url.path.contains(liveContainer.lastPathComponent) }, "扫描：清单里没有任何 LiveContainer 路径")
check(junkAndModel.items.allSatisfy { !$0.url.path.contains(sideStore.lastPathComponent) }, "扫描：清单里没有任何 SideStore 路径")
check(junkAndModel.notes.contains { $0.contains("archive.part") }, "扫描：说明里交代 archive.part 要保留")
check(junkAndModel.items.count == 14, "扫描：垃圾+模型正好 14 项（实际 \(junkAndModel.items.count)）")

// MARK: 删除垃圾 + 模型

let junkDelete = Array(junkAndModel.items)
let outcome = cleaner.delete(items: junkDelete, categories: [.junk, .model], historyDays: 30)
check(outcome.deleted == 14, "删除：垃圾+模型删掉 14 项（实际 \(outcome.deleted)）")
check(outcome.failed == 0, "删除：没有失败（实际 \(outcome.failed)）")
check(outcome.skipped == 0, "删除：没有跳过（实际 \(outcome.skipped)）")
check(!exists(swapDocs.appendingPathComponent("swap_runs.txt")), "删除：换脸日志没了")
check(!exists(helloDocs.appendingPathComponent("hello_log.txt")), "删除：剪辑日志没了")
check(!exists(snore.appendingPathComponent("Documents/snore_log.txt")), "删除：鼾声日志没了")
check(!exists(oldModel), "删除：旧模型包没了")
check(!exists(models.appendingPathComponent("emap.bin")), "删除：emap.bin 没了")
check(!exists(compiledOld), "删除：旧编译缓存 6.0 没了")
check(!exists(tmp.appendingPathComponent("swap_old.tmp")), "删除：旧 swap_ 临时文件没了")
check(!exists(tmp.appendingPathComponent("cut_old.tmp")), "删除：旧 cut_ 临时文件没了")
check(!exists(tmp.appendingPathComponent("LiveIn")), "删除：旧 LiveIn 目录没了")
check(!exists(staleDownload), "删除：共享临时区旧的通用 .tmp 没了")
check(!exists(swapTmp.appendingPathComponent("leftover_export.tmp")), "删除：容器真实 tmp 旧 .tmp 没了")
check(!exists(swapTmp.appendingPathComponent("frame_0001.bin")), "删除：容器真实 tmp 旧文件没了")
check(!exists(helloDocs.appendingPathComponent("cut_export.mov.tmp")), "删除：Documents 旧 .tmp 没了")
check(!exists(swapCaches.appendingPathComponent("stale-download.tmp")), "删除：Caches 旧 .tmp 没了")

check(exists(currentArc) && exists(currentSwap), "保留：当前换脸模型两个都还在")
check(exists(models.appendingPathComponent("version.txt")), "保留：version.txt")
check(exists(models.appendingPathComponent("chain.txt")), "保留：chain.txt")
check(exists(models.appendingPathComponent("archive.part")), "保留：没下完的 archive.part")
check(exists(swapDocs.appendingPathComponent("swap_idents/abc.pak")), "保留：身份存档")
check(exists(compiledCurrent), "保留：当前编译缓存 7.2")
check(exists(tmp.appendingPathComponent("swap_new.tmp")), "保留：6 小时内改过的临时文件")
check(exists(tmp.appendingPathComponent("not_ours.bin")), "保留：不认识的临时文件")
check(exists(freshDownload), "保留：共享临时区刚写的 .tmp")
check(exists(lcTmpFile), "保留：名字带 livecontainer 的 .tmp")
check(exists(swapTmp) && exists(swapTmp.appendingPathComponent("active_export.tmp")), "保留：容器真实 tmp 目录本身和刚写的文件")
check(exists(helloDocs.appendingPathComponent("cut_export_fresh.mov.tmp")), "保留：Documents 刚写的 .tmp")
check(exists(nightTmp), "保留：nights 里的 .tmp")
check(exists(modelTmp), "保留：模型包内部的 .tmp")
check(exists(compiledTmp), "保留：编译缓存内部的 .tmp")
check(exists(helloTmpLink), "保留：容器 tmp 符号链接本身不动")
check(exists(link), "保留：符号链接本身不动")
check(exists(external), "保留：符号链接指向的文件不动")
check(exists(liveContainer.appendingPathComponent("Documents/swap_runs.txt")), "保留：LiveContainer 里的同名日志")
check(exists(sideStore.appendingPathComponent("Documents/cut_old.mov")), "保留：SideStore 里的文件")
check(exists(orphan.appendingPathComponent("Documents/swap_runs.txt")), "保留：无 plist 容器的文件")

// 手工构造一条指向 LiveContainer 的“清单项”，delete 也必须拒绝。
let evilURL = liveContainer.appendingPathComponent("Documents/swap_runs.txt")
let evil = CleanItem(
    category: .junk, appName: "LiveContainer", bundleID: "com.kdt.livecontainer",
    containerName: "44444444-LCLC", url: evilURL, displayPath: "evil", bytes: 1,
    note: "evil", isDirectory: false, minAgeHours: 0, inSharedTmp: false, containerRoot: liveContainer
)
let evilOutcome = cleaner.delete(items: [evil], categories: [.junk, .model], historyDays: 30)
check(evilOutcome.deleted == 0, "安全：伪造的 LiveContainer 项删不掉")
check(evilOutcome.skipped == 1, "安全：伪造项被重扫闸门拦下（skipped=1）")
check(exists(evilURL), "安全：LiveContainer 文件原样在")

// MARK: 历史

let history = cleaner.scan(categories: [.history], historyDays: 30)
let historyPaths = Set(history.items.map { $0.url.standardizedFileURL.path })
check(historyPaths.contains(helloDocs.appendingPathComponent("cut_old.mov").path), "历史：40 天前的剪辑成片在清单里")
check(!historyPaths.contains(helloDocs.appendingPathComponent("cut_new.mov").path), "历史：2 天前的成片不动")
check(historyPaths.contains(nights.appendingPathComponent("20260101-000000").path), "历史：最老的一晚进清单")
check(!historyPaths.contains(nights.appendingPathComponent("20260102-000000").path), "历史：meta.json 坏掉的一晚不列")
check(!historyPaths.contains(nights.appendingPathComponent("20260103-000000").path), "历史：最新 3 晚不列（03）")
check(!historyPaths.contains(nights.appendingPathComponent("20260104-000000").path), "历史：最新 3 晚不列（04）")
check(!historyPaths.contains(nights.appendingPathComponent("20260105-000000").path), "历史：最新 3 晚不列（05）")
check(history.notes.contains { $0.contains("读不出来") }, "历史：坏 meta 有说明")
check(history.items.count == 2, "历史：正好 2 项（实际 \(history.items.count)）")

let historyOutcome = cleaner.delete(items: history.items, categories: [.history], historyDays: 30)
check(historyOutcome.deleted == 2, "历史删除：2 项都删掉（实际 \(historyOutcome.deleted)）")
check(!exists(helloDocs.appendingPathComponent("cut_old.mov")), "历史删除：旧成片没了")
check(exists(helloDocs.appendingPathComponent("cut_new.mov")), "历史删除：新成片还在")
check(!exists(nights.appendingPathComponent("20260101-000000")), "历史删除：最老一晚没了")
check(exists(nights.appendingPathComponent("20260102-000000")), "历史删除：坏 meta 那一晚保留")
check(exists(nights.appendingPathComponent("20260103-000000")), "历史删除：最新 3 晚保留（03）")
check(exists(nights.appendingPathComponent("20260104-000000")), "历史删除：最新 3 晚保留（04）")
check(exists(nights.appendingPathComponent("20260105-000000")), "历史删除：最新 3 晚保留（05）")

// MARK: 判决

if failures == 0 {
    print("CLEANER-VERDICT PASS")
    exit(0)
} else {
    print("CLEANER-VERDICT FAIL \(failures) 条")
    exit(1)
}
