import Foundation
import CoreGraphics

struct RestoreFaceTransform {
    let matrix: CGAffineTransform
    let scale: Double

    func apply(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: matrix.a * point.x + matrix.c * point.y + matrix.tx,
            y: matrix.b * point.x + matrix.d * point.y + matrix.ty
        )
    }
}

enum RestoreFaceMath {
    static let template: [CGPoint] = [
        CGPoint(x: 192.98138, y: 239.94708),
        CGPoint(x: 318.90277, y: 240.19360),
        CGPoint(x: 256.63416, y: 314.01935),
        CGPoint(x: 201.26117, y: 371.41043),
        CGPoint(x: 313.08905, y: 371.15118)
    ]

    static func similarityTransform(from source: [CGPoint], to destination: [CGPoint] = template) -> RestoreFaceTransform? {
        guard source.count == 5, destination.count == 5,
              source.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              destination.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let sourceCenter = center(of: source)
        let destinationCenter = center(of: destination)
        var covarianceXX = 0.0
        var covarianceXY = 0.0
        var covarianceYX = 0.0
        var covarianceYY = 0.0
        var variance = 0.0
        for index in 0..<5 {
            let x = source[index].x - sourceCenter.x
            let y = source[index].y - sourceCenter.y
            let targetX = destination[index].x - destinationCenter.x
            let targetY = destination[index].y - destinationCenter.y
            covarianceXX += x * targetX
            covarianceXY += x * targetY
            covarianceYX += y * targetX
            covarianceYY += y * targetY
            variance += x * x + y * y
        }
        guard variance > 0.000001 else { return nil }
        let cosinePart = covarianceXX + covarianceYY
        let sinePart = covarianceXY - covarianceYX
        let norm = (cosinePart * cosinePart + sinePart * sinePart).squareRoot()
        guard norm > 0.000001 else { return nil }
        let cosine = cosinePart / norm
        let sine = sinePart / norm
        let scale = norm / variance
        guard scale.isFinite, scale > 0.000001, scale < 1000 else { return nil }
        let tx = destinationCenter.x - scale * (cosine * sourceCenter.x - sine * sourceCenter.y)
        let ty = destinationCenter.y - scale * (sine * sourceCenter.x + cosine * sourceCenter.y)
        return RestoreFaceTransform(
            matrix: CGAffineTransform(a: scale * cosine, b: scale * sine, c: -scale * sine, d: scale * cosine, tx: tx, ty: ty),
            scale: scale
        )
    }

    static func imagePoint(_ normalized: CGPoint, faceBox: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: (faceBox.minX + normalized.x * faceBox.width) * imageSize.width,
            y: (1 - (faceBox.minY + normalized.y * faceBox.height)) * imageSize.height
        )
    }

    static func coreGraphicsTransform(_ transform: RestoreFaceTransform, size: Int) -> CGAffineTransform {
        let matrix = transform.matrix
        return CGAffineTransform(
            a: matrix.a,
            b: -matrix.b,
            c: -matrix.c,
            d: matrix.d,
            tx: matrix.tx,
            ty: Double(size) - matrix.ty
        )
    }

    static func paste(patch: CGImage, transform: RestoreFaceTransform, source: CGImage, canvas: RestorePixelCanvas) {
        let patchFlip = CGAffineTransform(translationX: 0, y: Double(patch.height)).scaledBy(x: 1, y: -1)
        let resize = CGAffineTransform(
            scaleX: Double(canvas.width) / Double(source.width),
            y: Double(canvas.height) / Double(source.height)
        )
        let canvasFlip = CGAffineTransform(translationX: 0, y: Double(canvas.height)).scaledBy(x: 1, y: -1)
        canvas.context.saveGState()
        canvas.context.interpolationQuality = .high
        canvas.context.concatenate(
            canvasFlip.concatenated(with: resize)
                .concatenated(with: patchFlip)
                .concatenated(with: transform.matrix.inverted())
        )
        canvas.context.draw(patch, in: CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
        canvas.context.restoreGState()
    }

    static func featherAlpha(pixelX: Int, pixelY: Int, size: Int) -> Double {
        guard size > 0 else { return 0 }
        let centerX = Double(size - 1) / 2
        let centerY = Double(size - 1) * 0.55
        let normalizedX = (Double(pixelX) - centerX) / (Double(size) * 0.37)
        let normalizedY = (Double(pixelY) - centerY) / (Double(size) * 0.48)
        let radius = (normalizedX * normalizedX + normalizedY * normalizedY).squareRoot()
        guard radius < 1 else { return 0 }
        guard radius > 0.82 else { return 1 }
        let value = (1 - radius) / 0.18
        return value * value * (3 - 2 * value)
    }

    static func featherMask(size: Int) throws -> CGImage {
        guard size > 0, size <= 2048 else { throw RestoreError.invalidDimensions }
        let bytesPerRow = ((size * 4 + 15) / 16) * 16
        guard let data = NSMutableData(length: bytesPerRow * size) else {
            throw RestoreError.fileOperation("无法创建人脸融合蒙版")
        }
        let bytes = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        for y in 0..<size {
            for x in 0..<size {
                let alpha = UInt8((featherAlpha(pixelX: x, pixelY: y, size: size) * 255).rounded())
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = alpha
                bytes[offset + 1] = alpha
                bytes[offset + 2] = alpha
                bytes[offset + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw RestoreError.fileOperation("无法创建人脸融合蒙版")
        }
        return image
    }

    private static func center(of points: [CGPoint]) -> CGPoint {
        CGPoint(
            x: points.reduce(0) { $0 + $1.x } / Double(points.count),
            y: points.reduce(0) { $0 + $1.y } / Double(points.count)
        )
    }
}
