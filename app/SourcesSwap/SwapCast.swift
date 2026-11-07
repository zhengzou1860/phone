import CoreML
import CoreVideo
import Foundation
import UIKit
import Vision

/// 多人换脸里的一个人：目标脸（视频里要找的那个人）的身份向量，加替换源的身份证。
/// 目标那一份只在预检的轨迹上比一次，源那一份才喂进换脸网。
struct SwapCastMember {
    var targetEmb: [Float]
    var targetLabel: String
    var sourceEmb: [Float]
    var sourceLabel: String
}

/// 目标照／源脸照 → 512 维身份证。两条来路走的是同一条「摆正 → 检最大那张脸 → 5 点对齐 → 裁 112 → 向量网」，
/// 目标那份只用来认视频里的脸，源那份才进换脸网。界面上传一张图就当场算，出片/预览不再碰照片。
enum SwapCast {
    struct Embedded {
        var emb: [Float]
        var shortSide: Double
        var note: String
    }

    /// 视频里的一张脸算不算这个目标：清晰的大脸同一人机上量到 0.72~0.86，不同人 −0.1~0.2。
    /// 但视频里的脸多半是小脸、侧脸、运动糊：同一人会掉到 0.5 上下，不同人偶尔也能冲到 0.5~0.6。
    /// 这一条由界面上那格「认人阈值」拖（存下来，下次开还在）：往低调＝远一点、糊一点的脸也换得到，
    /// 往高调＝只换有把握的那几张。最低给到 0.10＝基本不看余弦，用来现场判「这张脸到底认不认得出」。
    /// 没拖过就用 0.55（0.45 起上机定下的那道）。
    static let cosMin: Double = 0.10
    static let cosMax: Double = 0.60
    static let cosKey = "swap.matchCos"
    static var matchCos: Double {
        guard let n = UserDefaults.standard.object(forKey: cosKey) as? NSNumber else { return 0.55 }
        return min(max(n.doubleValue, cosMin), cosMax)
    }

    /// 清楚的线：短边够到它，112 裁片的上采样就不超过 1.75 倍。这条按进链帧上的像素算。
    static let identMinPx: Double = 64

    /// 够得着这条线的脸才量身份，而且这条要跟着进链窗口折算——出片 1920 ⇒ 64 px（＝上面那条本身），
    /// 预览小窗只有 640，同一个人到这一格里像素少 3 倍，门槛不跟着缩就永远够不着。
    /// 0.45 起那道写死的 64 px 就是这么把多人镜头里除最近那张全挡在门外（短边 36~63 px 根本不量身份），
    /// 看着就成了「只换最大的」；而 0.44 的日志里这些短边还能认出人：目标 0.45~0.64／路人 ≤0.44。
    static func identFloor(longEdge: Int) -> Double { identMinPx * Double(longEdge) / 1920.0 }

    /// 糊过一档（短边够不到 identMinPx）的裁片是上采样糊出来的，整段余弦往上挤：目标掉到 0.5 上下、
    /// 路人也能冲到 0.44。这一档不动界面那道数，只多要一道「领先第二名」——选了哪道就照哪道判。
    static let matchMargin: Double = 0.15

    /// 这张脸的余弦算不算认出来了：两档都用界面选的那道闸门，糊档另要领先第二名。
    static func accept(cos: Double, second: Double, shortSide: Double) -> Bool {
        guard cos >= matchCos else { return false }
        return shortSide < identMinPx ? cos - second >= matchMargin : true
    }

    /// 注册用的那两张网挂在一条串行队列上：连着传三张目标照只装一次。
    /// 出片/预览开始前必须 release()：两条链路各装一份引擎＝两份几百 MB 的足迹。
    private static let q = DispatchQueue(label: "swap.cast")
    private static var engine: FsxEngine?

    static func release() {
        q.sync {
            engine = nil
        }
    }

    /// 一张人脸照片 → 身份向量。回调在主线程；失败把原因带回来，不许静默变成「没检测到」。
    static func embed(image: UIImage, tag: String,
                      onLine: @escaping (String) -> Void,
                      done: @escaping (Embedded?, String) -> Void) {
        q.async {
            if engine == nil {
                onLine("\(tag) 要算特征：先装两张网（第一次到手机上要等一会儿）")
                let got = FsxEngine.load(units: .cpuOnly, onLine: onLine)
                guard let e = got.engine else {
                    DispatchQueue.main.async { done(nil, "\(tag) 装网失败：\n" + got.note) }
                    return
                }
                engine = e
            }
            guard let engine = engine else {
                DispatchQueue.main.async { done(nil, "\(tag) 手上没有引擎") }
                return
            }
            let (r, why) = faceEmbedding(image: image, engine: engine, tag: tag, onLine: onLine)
            DispatchQueue.main.async { done(r, why) }
        }
    }

    /// 对齐、裁 112、过向量网。这里和整片那条源脸链一个字不差：同一条尺量出来才比得了。
    static func faceEmbedding(image: UIImage, engine: FsxEngine, tag: String,
                              onLine: (String) -> Void) -> (Embedded?, String) {
        let up = SwapVision.uprightImage(image)
        guard let cg = up.cg else { return (nil, "\(tag) 取不出像素：\(up.note)") }
        let req = VNDetectFaceLandmarksRequest()
        let (obs, err) = SwapVision.faces(cg, req)
        if !err.isEmpty { onLine("\(tag) 检测：\(err)") }
        guard let l = SwapVision.largest(obs, w: cg.width, h: cg.height) else {
            return (nil, "\(tag) 这张图里没检到脸（\(up.note)）")
        }
        onLine("\(tag) " + SwapVision.settleOrigin(face: obs[l.index])
            + "｜短边 \(String(format: "%.0f", l.shortSide)) px")
        let (pts, src) = SwapVision.sendPoints(face: obs[l.index], w: cg.width, h: cg.height)
        guard let pl = FsxGeo.place(pts: pts, src: src, shortSide: l.shortSide) else {
            return (nil, "\(tag) 5 点映不进模板")
        }
        guard !pl.mirrored else {
            return (nil, "\(tag) 5 点手性与模板相反（y 口径判反），这张照片用不了")
        }
        let pb = SwapTech.pixelBuffer(from: cg)
        guard let buf = pb.pb else { return (nil, "\(tag) 静帧 \(pb.note)") }
        var crop = [Float](repeating: 0, count: 3 * FsxGeo.side112 * FsxGeo.side112)
        let ok = SwapTech.withPixels(buf) { base, bpr -> Bool in
            FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: bpr, w: cg.width, h: cg.height,
                            fwd: pl.fwd112, size: FsxGeo.side112, out: &crop)
        }
        guard ok == true else { return (nil, "\(tag) 裁不出 112") }
        let id = engine.embedding(crop112_01: crop)
        guard !id.emb.isEmpty, id.rawNorm > 0.5 else {
            return (nil, "\(tag) 身份证失败：\(id.note)｜模长 \(String(format: "%.3f", id.rawNorm))（要 >0.5）")
        }
        onLine("\(tag) 身份证 \(id.emb.count) 维／模长 \(String(format: "%.2f", id.rawNorm))｜\(id.note)")
        return (Embedded(emb: id.emb, shortSide: l.shortSide,
                         note: "短边 \(String(format: "%.0f", l.shortSide)) px／模长 \(String(format: "%.2f", id.rawNorm))"),
                "")
    }

    /// 这一张脸最像目标表里的谁；一个都不像也把最高的那个余弦带回来，日志里才判得了闸门。
    static func nearest(_ emb: [Float], members: [SwapCastMember])
        -> (index: Int, cos: Double, second: Double) {
        guard !emb.isEmpty, !members.isEmpty else { return (-1, -9, -9) }
        var bi = -1
        var bc = -2.0
        var sc = -2.0
        for (i, m) in members.enumerated() {
            let c = FsxMath.cosine(emb, m.targetEmb)
            if c > bc { sc = bc; bc = c; bi = i } else if c > sc { sc = c }
        }
        return (bi, bc, sc)
    }

    /// 新选的源脸照 → 存档。存不下也把向量带回去：这一趟还能跑，只是下次要重选。
    static func saveSource(emb: [Float], onLine: (String) -> Void)
        -> (id: String, name: String, note: String) {
        let sv = SwapIdents.save(emb: emb, taken: SwapIdents.list())
        onLine("源脸存档：\(sv.note)")
        return (sv.id, sv.name, sv.note)
    }
}
