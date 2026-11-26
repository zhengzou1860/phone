import Foundation
import CoreGraphics

struct RestoreMaskPoint: Codable, Equatable {
    var x: Double
    var y: Double

    func clamped() -> RestoreMaskPoint {
        RestoreMaskPoint(
            x: x.isFinite ? min(1, max(0, x)) : 0,
            y: y.isFinite ? min(1, max(0, y)) : 0
        )
    }
}

struct RestoreMaskStroke: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var points: [RestoreMaskPoint]
    var brushSize: Double
    var erasing: Bool = false

    func sanitized() -> RestoreMaskStroke {
        RestoreMaskStroke(
            id: id,
            points: points.map { $0.clamped() },
            brushSize: brushSize.isFinite ? min(0.5, max(0.002, brushSize)) : 0.04,
            erasing: erasing
        )
    }
}

struct RestoreMask: Codable, Equatable {
    var strokes: [RestoreMaskStroke] = []

    var isEmpty: Bool { !strokes.contains { !$0.erasing && !$0.points.isEmpty } }

    mutating func append(_ stroke: RestoreMaskStroke) {
        strokes.append(stroke.sanitized())
    }

    mutating func removeLast() {
        if !strokes.isEmpty { strokes.removeLast() }
    }

    func sanitized() -> RestoreMask {
        RestoreMask(strokes: strokes.map { $0.sanitized() }.filter { !$0.points.isEmpty })
    }

    func rasterized(width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else { throw RestoreError.invalidDimensions }
        guard !isEmpty else { throw RestoreError.emptyMask }
        let bytesPerRow = ((width + 15) / 16) * 16
        guard let data = NSMutableData(length: bytesPerRow * height) else {
            throw RestoreError.fileOperation("无法创建修补蒙版")
        }
        let bytes = data.mutableBytes
        let space = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
                data: bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            throw RestoreError.fileOperation("无法创建修补蒙版")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let scale = Double(min(width, height))
        for stroke in sanitized().strokes {
            context.setFillColor(CGColor(gray: stroke.erasing ? 0 : 1, alpha: 1))
            context.setStrokeColor(CGColor(gray: stroke.erasing ? 0 : 1, alpha: 1))
            context.setLineWidth(stroke.brushSize * scale)
            guard let first = stroke.points.first else { continue }
            if stroke.points.count == 1 {
                let radius = stroke.brushSize * scale / 2
                context.fillEllipse(in: CGRect(
                    x: first.x * Double(width) - radius,
                    y: (1 - first.y) * Double(height) - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                continue
            }
            context.beginPath()
            context.move(to: CGPoint(x: first.x * Double(width), y: (1 - first.y) * Double(height)))
            for point in stroke.points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x * Double(width), y: (1 - point.y) * Double(height)))
            }
            context.strokePath()
        }
        guard let image = context.makeImage() else { throw RestoreError.fileOperation("无法生成修补蒙版") }
        return image
    }
}
