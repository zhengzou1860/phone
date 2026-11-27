import Foundation
import CoreML
import CoreGraphics

enum RestoreSuperResolutionRunner {
    static func run(
        from url: URL,
        modelURL: URL,
        spec: RestoreModelSpec,
        outputWidth: Int,
        outputHeight: Int,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let decoded = try RestoreInferenceCore.decode(url)
        let scale = min(Double(outputWidth) / Double(decoded.width), Double(outputHeight) / Double(decoded.height))
        let target = RestoreMath.fittedSize(width: decoded.width, height: decoded.height, scale: scale, maxLongEdge: max(outputWidth, outputHeight))
        try RestoreAIMath.validateOutput(width: target.width, height: target.height, isSuperResolution: true)
        let model = try RestoreInferenceCore.loadModel(modelURL, spec: spec)
        let tileSize = spec.tileSize
        let overlap = spec.overlap
        let tiles = RestoreAIMath.tilePlan(
            width: decoded.width,
            height: decoded.height,
            tileSize: tileSize,
            overlap: overlap,
            outputScale: scale
        )
        guard !tiles.isEmpty else { throw RestoreError.invalidDimensions }
        let canvas = try RestorePixelCanvas(width: target.width, height: target.height)
        let weights = try RestoreBlendWeights(width: target.width, height: target.height)
        let inputDataType: MLMultiArrayDataType = spec.dataType == .float16 ? .float16 : .float32
        let input = try MLMultiArray(shape: spec.inputShape.map { NSNumber(value: $0) }, dataType: inputDataType)
        RestoreJournal.line("AI 超分：\(decoded.width)×\(decoded.height)，\(tiles.count) 个 \(tileSize)px 小块，输出 \(target.width)×\(target.height)")

        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            let sourceTile = try RestoreInferenceCore.sourceTile(decoded.image, originX: tile.originX, originY: tile.originY, size: tileSize)
            try fillRGB(input, from: sourceTile, channels: 3, minimum: 0, maximum: 1, dataType: spec.dataType)
            let prediction = try RestoreInferenceCore.predict(model, input: input, spec: spec)
            let outputSize = try RestoreInferenceCore.imageShape(prediction)
            let tileImage = try makeOutputImage(prediction, width: outputSize.width, height: outputSize.height, minimum: 0, maximum: 1, dataType: spec.dataType)
            try RestoreInferenceCore.blend(
                canvas: canvas,
                weights: weights,
                tileImage: tileImage,
                originX: tile.originX,
                originY: tile.originY,
                tileSize: tileSize,
                overlap: overlap,
                overlapLeft: tile.overlapLeft,
                overlapRight: tile.overlapRight,
                overlapTop: tile.overlapTop,
                overlapBottom: tile.overlapBottom,
                sourceImageWidth: decoded.width,
                sourceImageHeight: decoded.height,
                maskImage: nil
            )
            await progress(0.1 + Double(index + 1) / Double(tiles.count) * 0.84, "AI 超分 \(index + 1)/\(tiles.count) 块")
        }
        try Task.checkCancellation()
        await progress(0.96, "编码 AI 超分结果")
        RestoreJournal.line("AI 超分：\(tiles.count) 个分块全部完成")
        return try await RestoreInferenceCore.writeJPEG(canvas.makeImage())
    }

    private static func fillRGB(_ array: MLMultiArray, from image: CGImage, channels: Int, minimum: Float, maximum: Float, dataType: RestoreModelDataType) throws {
        guard image.width > 0, image.height > 0,
              let provider = image.dataProvider,
              let data = provider.data as Data? else {
            throw RestoreError.inferenceFailed("超分输入图像格式无效")
        }
        let pixels = (data as NSData).bytes.assumingMemoryBound(to: UInt8.self)
        let count = channels * image.width * image.height
        let plane = image.width * image.height
        switch dataType {
        case .float16:
            let destination = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            for channel in 0..<channels {
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let value = Float(pixels[y * image.bytesPerRow + x * 4 + channel]) / 255
                        destination[channel * plane + y * image.width + x] = Float16(min(maximum, max(minimum, value)))
                    }
                }
            }
        case .float32:
            let destination = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for channel in 0..<channels {
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let value = Float(pixels[y * image.bytesPerRow + x * 4 + channel]) / 255
                        destination[channel * plane + y * image.width + x] = min(maximum, max(minimum, value))
                    }
                }
            }
        }
    }

    private static func makeOutputImage(_ array: MLMultiArray, width: Int, height: Int, minimum: Float, maximum: Float, dataType: RestoreModelDataType) throws -> CGImage {
        let count = 3 * width * height
        let bytesPerRow = ((width * 4 + 15) / 16) * 16
        guard let data = NSMutableData(length: bytesPerRow * height) else {
            throw RestoreError.inferenceFailed("无法转换超分输出")
        }
        let destination = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        switch dataType {
        case .float16:
            let source = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            writeOutput(source, width: width, height: height, bytesPerRow: bytesPerRow, destination: destination, minimum: minimum, maximum: maximum)
        case .float32:
            let source = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            writeOutput(source, width: width, height: height, bytesPerRow: bytesPerRow, destination: destination, minimum: minimum, maximum: maximum)
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw RestoreError.inferenceFailed("无法生成超分图像")
        }
        return image
    }

    private static func writeOutput<Element: BinaryFloatingPoint>(
        _ source: UnsafePointer<Element>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        destination: UnsafeMutablePointer<UInt8>,
        minimum: Float,
        maximum: Float
    ) {
        let plane = width * height
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * width + x
                let pixel = (y * bytesPerRow) + x * 4
                for channel in 0..<3 {
                    let raw = Float(source[channel * plane + offset])
                    let normalized = raw.isFinite ? min(maximum, max(minimum, raw)) : minimum
                    destination[pixel + channel] = UInt8((normalized * 255).rounded())
                }
                destination[pixel + 3] = 255
            }
        }
    }
}
