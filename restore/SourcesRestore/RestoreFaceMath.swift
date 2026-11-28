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
        let height = Double(size)
        return CGAffineTransform(
            a: matrix.a,
            b: -matrix.b,
            c: -matrix.c,
            d: matrix.d,
            tx: matrix.c * height + matrix.tx,
            ty: height - matrix.d * height - matrix.ty
        )
    }

    static func paste(patch: CGImage, transform: RestoreFaceTransform, source: CGImage, canvas: RestorePixelCanvas) {
        guard patch.bitsPerComponent == 8, patch.bitsPerPixel == 32,
              patch.bytesPerRow >= patch.width * 4,
              let provider = patch.dataProvider,
              let providerData = CGDataProviderCopyData(provider) as Data?,
              providerData.count >= patch.bytesPerRow * patch.height else { return }
        let patchBytes = (providerData as NSData).bytes.assumingMemoryBound(to: UInt8.self)
        let canvasBytes = canvas.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let inverse = transform.matrix.inverted()
        let scaleX = Double(canvas.width) / Double(source.width)
        let scaleY = Double(canvas.height) / Double(source.height)
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: patch.width, y: 0),
            CGPoint(x: 0, y: patch.height),
            CGPoint(x: patch.width, y: patch.height)
        ].map { $0.applying(transform.matrix) }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let minimumX = corners.map { $0.x * scaleX }.min() ?? 0
        let maximumX = corners.map { $0.x * scaleX }.max() ?? 0
        let minimumY = corners.map { $0.y * scaleY }.min() ?? 0
        let maximumY = corners.map { $0.y * scaleY }.max() ?? 0
        let startX = max(0, Int(minimumX.rounded(.down)))
        let endX = min(canvas.width, Int(maximumX.rounded(.up)))
        let startY = max(0, Int(minimumY.rounded(.down)))
        let endY = min(canvas.height, Int(maximumY.rounded(.up)))
        guard startX < endX, startY < endY else { return }
        for y in startY..<endY {
            let sourceY = (Double(y) + 0.5) / scaleY
            for x in startX..<endX {
                let sourceX = (Double(x) + 0.5) / scaleX
                let point = CGPoint(x: sourceX, y: sourceY).applying(inverse)
                let sample = bilinearSample(
                    patchBytes,
                    bytesPerRow: patch.bytesPerRow,
                    width: patch.width,
                    height: patch.height,
                    x: point.x - 0.5,
                    y: point.y - 0.5
                )
                guard sample.alpha > 0 else { continue }
                let remainingAlpha = 255 - sample.alpha
                let offset = y * canvas.bytesPerRow + x * 4
                canvasBytes[offset] = UInt8(max(0, min(255, sample.red + Int(canvasBytes[offset]) * remainingAlpha / 255)))
                canvasBytes[offset + 1] = UInt8(max(0, min(255, sample.green + Int(canvasBytes[offset + 1]) * remainingAlpha / 255)))
                canvasBytes[offset + 2] = UInt8(max(0, min(255, sample.blue + Int(canvasBytes[offset + 2]) * remainingAlpha / 255)))
                canvasBytes[offset + 3] = 255
            }
        }
    }

    private static func bilinearSample(
        _ bytes: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        x: Double,
        y: Double
    ) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else {
            return (0, 0, 0, 0)
        }
        let x0 = Int(x.rounded(.down))
        let y0 = Int(y.rounded(.down))
        let x1 = min(width - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let fractionX = x - Double(x0)
        let fractionY = y - Double(y0)
        let topWeight = 1 - fractionY
        let bottomWeight = fractionY
        let leftWeight = 1 - fractionX
        let rightWeight = fractionX
        func pixel(_ pixelX: Int, _ pixelY: Int) -> (Int, Int, Int, Int) {
            let offset = pixelY * bytesPerRow + pixelX * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
        }
        let topLeft = pixel(x0, y0)
        let topRight = pixel(x1, y0)
        let bottomLeft = pixel(x0, y1)
        let bottomRight = pixel(x1, y1)
        func channel(_ topLeftValue: Int, _ topRightValue: Int, _ bottomLeftValue: Int, _ bottomRightValue: Int) -> Int {
            let value = Double(topLeftValue) * topWeight * leftWeight
                + Double(topRightValue) * topWeight * rightWeight
                + Double(bottomLeftValue) * bottomWeight * leftWeight
                + Double(bottomRightValue) * bottomWeight * rightWeight
            return Int(value.rounded())
        }
        return (
            channel(topLeft.0, topRight.0, bottomLeft.0, bottomRight.0),
            channel(topLeft.1, topRight.1, bottomLeft.1, bottomRight.1),
            channel(topLeft.2, topRight.2, bottomLeft.2, bottomRight.2),
            channel(topLeft.3, topRight.3, bottomLeft.3, bottomRight.3)
        )
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
