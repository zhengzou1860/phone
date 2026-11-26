import Foundation
import CoreML
import CoreImage

enum RestoreInpaintingRunner {
    static func run(
        from url: URL,
        modelURL: URL,
        spec: RestoreModelSpec,
        mask: RestoreMask,
        outputWidth: Int,
        outputHeight: Int,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        guard !mask.isEmpty else { throw RestoreError.emptyMask }
        let decoded = try RestoreInferenceCore.decode(url)
        let scale = min(Double(outputWidth) / Double(decoded.width), Double(outputHeight) / Double(decoded.height))
        let target = RestoreMath.fittedSize(width: decoded.width, height: decoded.height, scale: scale, maxLongEdge: max(outputWidth, outputHeight))
        try RestoreAIMath.validateOutput(width: target.width, height: target.height, isSuperResolution: false)
        let maskImage = try mask.rasterized(width: decoded.width, height: decoded.height)
        let maskSource = CIImage(cgImage: maskImage)
        let model = try RestoreInferenceCore.loadModel(modelURL, spec: spec)
        let tileSize = spec.tileSize
        let overlap = spec.overlap
        let allTiles = RestoreAIMath.tilePlan(
            width: decoded.width,
            height: decoded.height,
            tileSize: tileSize,
            overlap: overlap,
            outputScale: scale
        )
        let tiles = allTiles.filter { intersectsMask($0, mask: maskImage, imageWidth: decoded.width, imageHeight: decoded.height, tileSize: tileSize) }
        guard !tiles.isEmpty else { throw RestoreError.emptyMask }
        let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
        let canvas = try RestorePixelCanvas(width: target.width, height: target.height, source: decoded.image)
        let input = try MLMultiArray(shape: spec.inputShape.map { NSNumber(value: $0) }, dataType: .float32)
        RestoreJournal.line("AI 修补：\(decoded.width)×\(decoded.height)，蒙版命中 \(tiles.count) 个 \(tileSize)px 小块")

        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            let sourceTile = try RestoreInferenceCore.sourceTile(decoded.source, originX: tile.originX, originY: tile.originY, size: tileSize, context: context)
            let maskTile = try RestoreInferenceCore.maskTile(maskSource, originX: tile.originX, originY: tile.originY, size: tileSize, context: context)
            try fillInput(input, source: sourceTile, mask: maskTile)
            let prediction = try RestoreInferenceCore.predict(model, input: input, spec: spec)
            let tileImage = try makeOutputImage(prediction)
            try RestoreInferenceCore.blend(
                canvas: canvas,
                tileImage: tileImage,
                originX: tile.originX,
                originY: tile.originY,
                tileSize: tileSize,
                overlap: overlap,
                scale: scale,
                maskImage: maskTile
            )
            await progress(0.1 + Double(index + 1) / Double(tiles.count) * 0.84, "AI 修补 \(index + 1)/\(tiles.count) 块")
        }
        try Task.checkCancellation()
        await progress(0.96, "编码 AI 修补结果")
        RestoreJournal.line("AI 修补：\(tiles.count) 个分块全部完成")
        return try RestoreInferenceCore.writeJPEG(canvas.makeImage())
    }

    private static func intersectsMask(_ tile: RestoreAITile, mask: CGImage, imageWidth: Int, imageHeight: Int, tileSize: Int) -> Bool {
        let minX = max(0, tile.originX)
        let minY = max(0, tile.originY)
        let maxX = min(imageWidth, tile.originX + tileSize)
        let maxY = min(imageHeight, tile.originY + tileSize)
        guard minX < maxX, minY < maxY,
              let provider = mask.dataProvider,
              let data = provider.data as Data? else { return false }
        let pixels = (data as NSData).bytes.assumingMemoryBound(to: UInt8.self)
        for y in minY..<maxY {
            let row = y * mask.bytesPerRow
            for x in minX..<maxX where pixels[row + x] > 0 {
                return true
            }
        }
        return false
    }

    private static func fillInput(_ array: MLMultiArray, source: CGImage, mask: CGImage) throws {
        guard source.width == 512, source.height == 512,
              mask.width == 512, mask.height == 512,
              let sourceProvider = source.dataProvider,
              let maskProvider = mask.dataProvider,
              let sourceData = sourceProvider.data as Data?,
              let maskData = maskProvider.data as Data? else {
            throw RestoreError.inferenceFailed("修补输入图像格式无效")
        }
        let sourcePixels = (sourceData as NSData).bytes.assumingMemoryBound(to: UInt8.self)
        let maskPixels = (maskData as NSData).bytes.assumingMemoryBound(to: UInt8.self)
        let destination = array.dataPointer.bindMemory(to: Float.self, capacity: 4 * 512 * 512)
        let plane = 512 * 512
        for y in 0..<512 {
            for x in 0..<512 {
                let offset = y * 512 + x
                for channel in 0..<3 {
                    let value = Float(sourcePixels[y * source.bytesPerRow + x * 4 + channel])
                    destination[channel * plane + offset] = value / 127.5 - 1
                }
                destination[3 * plane + offset] = Float(maskPixels[y * mask.bytesPerRow + x * 4]) / 255
            }
        }
    }

    private static func makeOutputImage(_ array: MLMultiArray) throws -> CGImage {
        let size = try RestoreInferenceCore.imageShape(array)
        guard size.width == 512, size.height == 512 else { throw RestoreError.inferenceFailed("修补模型输出不是 512×512") }
        let width = size.width
        let height = size.height
        let plane = width * height
        let source = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        let bytesPerRow = width * 4
        guard let data = NSMutableData(length: bytesPerRow * height) else {
            throw RestoreError.inferenceFailed("无法转换修补输出")
        }
        let destination = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let space = CGColorSpaceCreateDeviceRGB()
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * width + x
                let pixel = y * bytesPerRow + x * 4
                for channel in 0..<3 {
                    let raw = Float(source[channel * plane + offset])
                    let safe = raw.isFinite ? min(1, max(-1, raw)) : 0
                    destination[pixel + channel] = UInt8(((safe + 1) * 127.5).rounded())
                }
                destination[pixel + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue,
                provider: provider,
                decode: nil,
                shouldInterpolate: true
              ) else {
            throw RestoreError.inferenceFailed("无法生成修补图像")
        }
        return image
    }
}
