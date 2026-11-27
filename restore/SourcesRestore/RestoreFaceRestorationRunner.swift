import Foundation
import CoreGraphics
import CoreML
import Vision

enum RestoreFaceRestorationRunner {
    static let maximumFaces = 8

    static func restore(
        canvas: RestorePixelCanvas,
        source: CGImage,
        modelURL: URL,
        spec: RestoreModelSpec,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> Int {
        try Task.checkCancellation()
        let model = try RestoreInferenceCore.loadModel(modelURL, spec: spec)
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        let handler = VNImageRequestHandler(cgImage: source, orientation: .up)
        try handler.perform([request])
        let observations = (request.results as? [VNFaceObservation] ?? [])
            .filter { $0.boundingBox.width * CGFloat(source.width) >= 24 && $0.boundingBox.height * CGFloat(source.height) >= 24 }
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        guard !observations.isEmpty else {
            RestoreJournal.line("人脸补全：未检测到需要处理的人脸")
            await progress(0.94, "未检测到人脸，保留超分结果")
            return 0
        }
        let selected = Array(observations.prefix(maximumFaces))
        if observations.count > selected.count {
            RestoreJournal.line("人脸补全：检测到 \(observations.count) 张脸，本轮处理前 \(selected.count) 张")
        }
        let mask = try RestoreFaceMath.featherMask(size: spec.tileSize)
        var completed = 0
        for (index, observation) in selected.enumerated() {
            try Task.checkCancellation()
            guard let transform = alignment(for: observation, source: source) else {
                RestoreJournal.line("人脸补全：跳过五官 landmarks 不完整的脸 \(index + 1)")
                continue
            }
            guard let aligned = alignedFace(source: source, transform: transform, size: spec.tileSize) else {
                throw RestoreError.inferenceFailed("无法对齐人脸")
            }
            let restored = try RestoreInferenceCore.predictImage(model, image: aligned, spec: spec)
            guard let patch = maskedPatch(image: restored, mask: mask) else {
                throw RestoreError.inferenceFailed("无法生成人脸融合图像")
            }
            paste(patch: patch, transform: transform, source: source, canvas: canvas)
            completed += 1
            let value = 0.80 + Double(index + 1) / Double(selected.count) * 0.16
            await progress(value, "人脸细节补全 \(index + 1)/\(selected.count)")
        }
        RestoreJournal.line("人脸补全：完成 \(completed) 张脸，\(spec.technicalSummary)")
        if completed == 0 {
            await progress(0.94, "人脸特征不足，保留超分结果")
        }
        return completed
    }

    private static func alignment(for observation: VNFaceObservation, source: CGImage) -> RestoreFaceTransform? {
        guard let landmarks = observation.landmarks else { return nil }
        func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let points = landmarkPoints(region, observation: observation, source: source), !points.isEmpty else { return nil }
            return CGPoint(
                x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
            )
        }
        guard let firstEye = center(landmarks.leftEye),
              let secondEye = center(landmarks.rightEye),
              let nose = noseTip(landmarks.nose, observation: observation, source: source),
              let mouth = mouthCorners(landmarks.outerLips, observation: observation, source: source) else { return nil }
        let eyes = [firstEye, secondEye].sorted { $0.x < $1.x }
        let transform = RestoreFaceMath.similarityTransform(from: [eyes[0], eyes[1], nose, mouth.left, mouth.right])
        let faceWidth = observation.boundingBox.width * CGFloat(source.width)
        let faceHeight = observation.boundingBox.height * CGFloat(source.height)
        guard let transform, min(faceWidth, faceHeight) * transform.scale >= 32 else { return nil }
        return transform
    }

    private static func noseTip(_ region: VNFaceLandmarkRegion2D?, observation: VNFaceObservation, source: CGImage) -> CGPoint? {
        guard let points = landmarkPoints(region, observation: observation, source: source), !points.isEmpty else { return nil }
        let lowest = points.map { $0.y }.max() ?? 0
        let tipPoints = points.filter { $0.y >= lowest - CGFloat(source.height) * 0.008 }
        return average(tipPoints)
    }

    private static func mouthCorners(_ region: VNFaceLandmarkRegion2D?, observation: VNFaceObservation, source: CGImage) -> (left: CGPoint, right: CGPoint)? {
        guard let points = landmarkPoints(region, observation: observation, source: source), points.count >= 4 else { return nil }
        let minimumX = points.map { $0.x }.min() ?? 0
        let maximumX = points.map { $0.x }.max() ?? 0
        let span = maximumX - minimumX
        guard span > 1 else { return nil }
        let edge = span * 0.18
        let leftPoints = points.filter { $0.x <= minimumX + edge }
        let rightPoints = points.filter { $0.x >= maximumX - edge }
        return (average(leftPoints), average(rightPoints))
    }

    private static func landmarkPoints(_ region: VNFaceLandmarkRegion2D?, observation: VNFaceObservation, source: CGImage) -> [CGPoint]? {
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
        let box = observation.boundingBox
        let size = CGSize(width: source.width, height: source.height)
        return points.map { RestoreFaceMath.imagePoint($0, faceBox: box, imageSize: size) }
    }

    private static func average(_ points: [CGPoint]) -> CGPoint {
        CGPoint(
            x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
            y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        )
    }

    private static func alignedFace(source: CGImage, transform: RestoreFaceTransform, size: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .high
        context.saveGState()
        context.concatenate(transform.matrix)
        context.draw(source, at: .zero)
        context.restoreGState()
        return context.makeImage()
    }

    private static func maskedPatch(image: CGImage, mask: CGImage) -> CGImage? {
        guard image.width == mask.width, image.height == mask.height else { return nil }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setBlendMode(.destinationIn)
        context.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
        return context.makeImage()
    }

    private static func paste(patch: CGImage, transform: RestoreFaceTransform, source: CGImage, canvas: RestorePixelCanvas) {
        let outputScale = CGAffineTransform(
            scaleX: Double(canvas.width) / Double(source.width),
            y: Double(canvas.height) / Double(source.height)
        )
        canvas.context.saveGState()
        canvas.context.interpolationQuality = .high
        canvas.context.concatenate(outputScale.concatenated(transform.matrix.inverted()))
        canvas.context.draw(patch, in: CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
        canvas.context.restoreGState()
    }
}
