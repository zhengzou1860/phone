import Foundation
import SwiftUI

// MARK: - 图上那一格怎么画
//
// 一根柱子两样信息：高度＝这一格有多长时间在打鼾（占比），颜色＝这一格里最响的那声有多响。
// 中断单独画一条通高的红竖线——用户第二天早上要找的就是「什么时候停的、停了多久」。

/// 电平 → 颜色：-60 dBFS 以下偏绿（基本是本底），往上到 -20 转红。
/// 只是给肉眼分的档，不是绝对刻度，报告里该看的还是那个 dBFS 数。
func snoreLevelColor(_ db: Double) -> Color {
    let t = min(1.0, max(0.0, (db + 60.0) / 40.0))
    return Color(hue: 0.33 * (1.0 - t), saturation: 0.85, brightness: 0.9)
}

struct SnoreChart: View {
    let points: [SnoreChartPoint]
    let start: Date
    let span: Double
    var chartHeight: CGFloat = 160

    var body: some View {
        Canvas { ctx, size in
            let bg = Path(CGRect(origin: .zero, size: size))
            ctx.fill(bg, with: .color(.secondary.opacity(0.10)))
            guard !points.isEmpty, span > 1 else {
                ctx.draw(Text("还没有数据：点上面的开始按钮，或者这一晚的曲线是空的")
                            .font(.system(size: 11)).foregroundColor(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let secPerPt = size.width / CGFloat(span)

            // 时间刻度：整晚就两小时一格，短会话加密
            let stepSec: Double = span > 4 * 3600 ? 2 * 3600 : (span > 2 * 3600 ? 3600 : (span > 1800 ? 1800 : 600))
            var t = 0.0
            while t <= span {
                let x = CGFloat(t) * secPerPt
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
                let label = DateFormatter()
                label.dateFormat = span > 3600 ? "HH" : "HH:mm"
                let txt = label.string(from: start.addingTimeInterval(t))
                ctx.draw(Text(txt).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: min(max(x, 12), size.width - 12), y: size.height - 7))
                t += stepSec
            }

            for p in points {
                let x = CGFloat(p.t0) * secPerPt
                let w = max(1.0, CGFloat(p.dur) * secPerPt - 0.6)
                if p.stale {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)),
                             with: .color(.gray.opacity(0.22)))
                    continue
                }
                // 高度：鼾声占比开三次根。线性高的话「10% 在打」和「60% 在打」在图上看不出差别，
                // 而后者才是该一眼看见的那一晚。
                let h = CGFloat(pow(max(0.003, min(1.0, p.cov)), 1.0 / 3.0)) * size.height
                let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                ctx.fill(Path(rect), with: .color(snoreLevelColor(p.maxDb).opacity(0.85)))
                if p.hasVocal {
                    let dot = CGRect(x: x, y: 2, width: max(2.5, w), height: 3)
                    ctx.fill(Path(ellipseIn: dot), with: .color(.orange))
                }
                if p.hasGap {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(line, with: .color(.red), lineWidth: 1.6)
                }
            }
        }
        .frame(height: chartHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - 实时那一条电平尺

/// 「声音多大」在这一格上看：本底一根白线，现在的电平一根实心条，进门门限画一道虚位。
struct SnoreLevelBar: View {
    let level: Double
    let floorDb: Double
    var body: some View {
        GeometryReader { geo in
            let lo = -75.0, hi = -10.0
            let pos = { (db: Double) in
                CGFloat(min(1.0, max(0.0, (db - lo) / (hi - lo)))) * geo.size.width
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                Rectangle()
                    .fill(snoreLevelColor(level))
                    .frame(width: max(2, pos(level)), height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack {
                    Rectangle().fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: geo.size.height)
                        .offset(x: pos(floorDb))
                }
            }
        }
        .frame(height: 18)
    }
}

// MARK: - 一个小标签：值对上口径

struct SnoreStat: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
