import Foundation

// 只在 CI 的 mac 上跑：本机（Windows）没有 Swift 工具链，FsxGeo 这些逐式只能等装上手机才看得见结果。
// 0.37 那条「脸整张偏蓝」就是这么漏过去的——模型对账那三层是把 fixture 直接喂进网，
// 绕过了手机自己裁片那一步（裁片把 BGRA 内存序顺嘴读成 BGR，网照样跑、不报错，出来的脸整张发蓝）。
// 所以这一步把 FsxGeo 单独编成命令行、跑它那份 selfTest：几何、遮罩三刀、往下多贴、收口、裁片通道序一次全摊开。
let t = FsxGeo.selfTest()
print("GEO-SELFTEST " + t)
if t == "拟合失败" || t.contains("错") {
    print("GEO-VERDICT FAIL 上面那行里有一式没过（哪一格写着「错」就是哪一式断了）")
} else {
    print("GEO-VERDICT PASS 模板／往返／腐蚀糊／多贴 \(FsxGeo.extDown) 格／收口 \(FsxGeo.fadeDown) 格／裁片通道 全过")
}
