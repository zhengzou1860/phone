import Foundation
import CoreML
import CoreGraphics
import ImageIO

struct RestoreDecodedImage {
    let image: CGImage
    let width: Int
    let height: Int
}

struct RestorePixelCanvas {
    let width: Int
    let height: Int
    let data: NSMutableData
    let context: CGContext
    let bytesPerRow: Int

    init(width: Int, height: Int, source: CGImage? = nil) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw RestoreError.invalidDimensions }
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        guard let data = NSMutableData(length: bytesPerRow * height) else {
            throw RestoreError.fileOperation("无法分配照片画布内存")
        }
        self.data = data
        let bytes = data.mutableBytes
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
                data: bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw RestoreError.fileOperation("无法创建照片画布")
        }
        self.context = context
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let source {
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func makeImage() throws -> CGImage {
        guard let image = context.makeImage() else { throw RestoreError.fileOperation("无法读取照片画布") }
        return image
    }
}

final class RestoreBlendWeights {
    static let fullWeight: UInt16 = 4095

    private let width: Int
    private let height: Int
    private let data: NSMutableData
    private var coverageData: NSMutableData?

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw RestoreError.invalidDimensions }
        self.width = width
        self.height = height
        guard let data = NSMutableData(length: width * height * MemoryLayout<UInt16>.size) else {
            throw RestoreError.fileOperation("无法分配照片融合权重")
        }
        self.data = data
    }

    func prepareCoverage() throws {
        guard coverageData == nil else { return }
        guard let data = NSMutableData(length: width * height * MemoryLayout<UInt16>.size) else {
            throw RestoreError.fileOperation("无法分配照片蒙版权重")
        }
        coverageData = data
    }

    func blendWeight(pixelX: Int, pixelY: Int, weight: UInt16, coverageWeight: UInt16? = nil) -> Double {
        let index = pixelY * width + pixelX
        if let coverageWeight, let coverageData {
            let coverage = coverageData.mutableBytes.assumingMemoryBound(to: UInt16.self)
            coverage[index] = min(UInt16.max, coverage[index] &+ coverageWeight)
        }
        guard weight > 0 else { return 0 }
        let values = data.mutableBytes.assumingMemoryBound(to: UInt16.self)
        let total = min(UInt16.max, values[index] &+ weight)
        values[index] = total
        return Double(weight) / Double(total)
    }

    func composite(_ canvas: RestorePixelCanvas, over source: CGImage) throws {
        let bytesPerRow = width * 4
        guard let rowData = NSMutableData(length: bytesPerRow),
              let strip = CGContext(
                data: rowData.mutableBytes,
                width: width,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw RestoreError.fileOperation("无法创建照片合成缓冲")
        }
        strip.interpolationQuality = .high
        let weights = data.bytes.assumingMemoryBound(to: UInt16.self)
        let coverageWeights = coverageData?.bytes.assumingMemoryBound(to: UInt16.self)
        let prediction = canvas.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            if (y & 255) == 0 { try Task.checkCancellation() }
            strip.clear(CGRect(x: 0, y: 0, width: width, height: 1))
            let sourceY = min(source.height - 1, Int((Double(y) * Double(source.height) / Double(height)).rounded(.down)))
            let sourceEndY = max(sourceY + 1, Int((Double(y + 1) * Double(source.height) / Double(height)).rounded(.up)))
            if let row = source.cropping(to: CGRect(x: 0, y: sourceY, width: source.width, height: sourceEndY - sourceY)) {
                strip.draw(row, in: CGRect(x: 0, y: 0, width: width, height: 1))
            }
            let original = rowData.mutableBytes.assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let index = y * width + x
                let totalWeight = coverageWeights.map { $0[index] } ?? Self.fullWeight
                let coverage = totalWeight > 0 ? min(1, Double(weights[index]) / Double(totalWeight)) : 0
                let offset = index * 4
                for channel in 0..<3 {
                    let value = Double(prediction[offset + channel]) * coverage
                        + Double(original[x * 4 + channel]) * (1 - coverage)
                    prediction[offset + channel] = UInt8(max(0, min(255, value.rounded())))
                }
                prediction[offset + 3] = 255
            }
        }
    }
}

enum RestoreInferenceCore {
    static func decode(_ url: URL) throws -> RestoreDecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: RestoreAIMath.maximumSourceLongEdge
              ] as CFDictionary) else {
            throw RestoreError.unreadableImage
        }
        return RestoreDecodedImage(image: image, width: image.width, height: image.height)
    }

    static func geometry(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? NSDictionary,
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw RestoreError.unreadableImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? (height.intValue, width.intValue)
            : (width.intValue, height.intValue)
    }

    static func loadModel(_ url: URL, spec: RestoreModelSpec) throws -> MLModel {
        let configuration = MLModelConfiguration()
        switch spec.compute {
        case .neuralEngine: configuration.computeUnits = .cpuAndNeuralEngine
        case .gpu: configuration.computeUnits = .cpuAndGPU
        }
        do {
            let model = try MLModel(contentsOf: url, configuration: configuration)
            try validate(model, spec: spec)
            return model
        } catch let error as RestoreError {
            throw error
        } catch {
            throw RestoreError.modelLoadFailed(error.localizedDescription)
        }
    }

    static func sourceTile(_ image: CGImage, originX: Int, originY: Int, size: Int) throws -> CGImage {
        try drawTile(image, originX: originX, originY: originY, size: size, clear: false)
    }

    static func maskTile(_ image: CGImage, originX: Int, originY: Int, size: Int) throws -> CGImage {
        try drawTile(image, originX: originX, originY: originY, size: size, clear: true)
    }

    private static func drawTile(_ image: CGImage, originX: Int, originY: Int, size: Int, clear: Bool) throws -> CGImage {
        guard let tile = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw RestoreError.inferenceFailed("无法创建推理小块")
        }
        tile.interpolationQuality = .none
        if clear {
            tile.clear(CGRect(x: 0, y: 0, width: size, height: size))
        } else {
            tile.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            tile.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        let validWidth = min(size, image.width - originX)
        let validHeight = min(size, image.height - originY)
        if validWidth > 0, validHeight > 0,
           let cropped = image.cropping(to: CGRect(x: originX, y: originY, width: validWidth, height: validHeight)) {
            tile.draw(cropped, in: CGRect(x: 0, y: 0, width: validWidth, height: validHeight))
        }
        guard let rendered = tile.makeImage() else { throw RestoreError.inferenceFailed("无法生成推理小块") }
        guard !clear, validWidth > 0, validHeight > 0,
              (validWidth < size || validHeight < size) else {
            return rendered
        }
        let bytesPerRow = rendered.bytesPerRow
        guard rendered.bitsPerComponent == 8,
              rendered.bitsPerPixel == 32,
              let provider = rendered.dataProvider,
              let rawData = provider.data else {
            throw RestoreError.inferenceFailed("无法复制推理小块像素")
        }
        let sourceData = rawData as NSData
        guard sourceData.length >= bytesPerRow * size else {
            throw RestoreError.inferenceFailed("无法读取推理小块像素")
        }
        let sourceBytes = Array(sourceData as Data)
        func edgeColor(x: Int, y: Int) -> CGColor {
            let offset = y * bytesPerRow + x * 4
            return CGColor(
                red: CGFloat(sourceBytes[offset]) / 255,
                green: CGFloat(sourceBytes[offset + 1]) / 255,
                blue: CGFloat(sourceBytes[offset + 2]) / 255,
                alpha: CGFloat(sourceBytes[offset + 3]) / 255
            )
        }
        if validWidth < size {
            for y in 0..<validHeight {
                tile.setFillColor(edgeColor(x: validWidth - 1, y: y))
                tile.fill(CGRect(x: validWidth, y: y, width: size - validWidth, height: 1))
            }
        }
        if validHeight < size {
            for x in 0..<validWidth {
                tile.setFillColor(edgeColor(x: x, y: validHeight - 1))
                tile.fill(CGRect(x: x, y: validHeight, width: 1, height: size - validHeight))
            }
        }
        if validWidth < size, validHeight < size {
            tile.setFillColor(edgeColor(x: validWidth - 1, y: validHeight - 1))
            tile.fill(CGRect(x: validWidth, y: validHeight, width: size - validWidth, height: size - validHeight))
        }
        guard let result = tile.makeImage() else { throw RestoreError.inferenceFailed("无法生成推理小块") }
        return result
    }

    static func predict(_ model: MLModel, input: MLMultiArray, spec: RestoreModelSpec) throws -> MLMultiArray {
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [spec.inputName: MLFeatureValue(multiArray: input)])
            let result = try model.prediction(from: provider)
            guard let output = result.featureValue(for: spec.outputName)?.multiArrayValue else {
                throw RestoreError.inferenceFailed("模型没有返回 \(spec.outputName) 图像")
            }
            return output
        } catch let error as RestoreError {
            throw error
        } catch {
            throw RestoreError.inferenceFailed(error.localizedDescription)
        }
    }

    static func blend(
        canvas: RestorePixelCanvas,
        weights: RestoreBlendWeights,
        tileImage: CGImage,
        originX: Int,
        originY: Int,
        tileSize: Int,
        overlap: Int,
        overlapLeft: Int? = nil,
        overlapRight: Int? = nil,
        overlapTop: Int? = nil,
        overlapBottom: Int? = nil,
        sourceImageWidth: Int,
        sourceImageHeight: Int,
        maskImage: CGImage?
    ) throws {
        let validWidth = min(tileSize, sourceImageWidth - originX)
        let validHeight = min(tileSize, sourceImageHeight - originY)
        guard validWidth > 0, validHeight > 0,
              tileImage.width % tileSize == 0,
              tileImage.height % tileSize == 0 else {
            throw RestoreError.inferenceFailed("模型输出与有效图像尺寸不匹配")
        }
        let modelScaleX = tileImage.width / tileSize
        let modelScaleY = tileImage.height / tileSize
        let predictionRect = CGRect(
            x: 0,
            y: 0,
            width: validWidth * modelScaleX,
            height: validHeight * modelScaleY
        )
        guard let croppedPrediction = tileImage.cropping(to: predictionRect) else {
            throw RestoreError.inferenceFailed("无法裁掉模型输出的补边")
        }
        let scaleX = Double(canvas.width) / Double(sourceImageWidth)
        let scaleY = Double(canvas.height) / Double(sourceImageHeight)
        let outputOriginX = Int((Double(originX) * scaleX).rounded(.down))
        let outputOriginY = Int((Double(originY) * scaleY).rounded(.down))
        let outputEndX = Int((Double(originX + validWidth) * scaleX).rounded(.up))
        let outputEndY = Int((Double(originY + validHeight) * scaleY).rounded(.up))
        let outputWidth = max(1, outputEndX - outputOriginX)
        let outputHeight = max(1, outputEndY - outputOriginY)
        let tile = try RestorePixelCanvas(width: outputWidth, height: outputHeight)
        tile.context.interpolationQuality = .high
        tile.context.draw(croppedPrediction, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        let maskCanvas = try maskImage.map { image in
            guard image.width == tileSize, image.height == tileSize,
                  let cropped = image.cropping(to: CGRect(
                    x: 0,
                    y: 0,
                    width: validWidth,
                    height: validHeight
                  )) else {
                throw RestoreError.inferenceFailed("修补蒙版与有效图像尺寸不匹配")
            }
            let canvas = try RestorePixelCanvas(width: outputWidth, height: outputHeight)
            canvas.context.interpolationQuality = .high
            canvas.context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
            return canvas
        }
        let destinationBase = canvas.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let tileBase = tile.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let maskBase = maskCanvas?.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let minX = max(0, outputOriginX)
        let maxX = min(canvas.width, outputOriginX + outputWidth)
        let minY = max(0, outputOriginY)
        let maxY = min(canvas.height, outputOriginY + outputHeight)
        guard minX < maxX, minY < maxY else { return }
        if maskImage != nil { try weights.prepareCoverage() }

        let haloLeft = max(1, Double(overlapLeft ?? overlap) * scaleX)
        let haloRight = max(1, Double(overlapRight ?? overlap) * scaleX)
        let haloTop = max(1, Double(overlapTop ?? overlap) * scaleY)
        let haloBottom = max(1, Double(overlapBottom ?? overlap) * scaleY)
        for y in minY..<maxY {
            let localY = y - outputOriginY
            let vertical = quantizedWeight(
                pixel: y,
                origin: outputOriginY,
                size: outputHeight,
                sourceOrigin: originY,
                sourceSize: validHeight,
                sourceImageSize: sourceImageHeight,
                halo: haloTop,
                haloRight: haloBottom,
                quantum: Double(RestoreBlendWeights.fullWeight)
            )
            for x in minX..<maxX {
                let horizontal = quantizedWeight(
                    pixel: x,
                    origin: outputOriginX,
                    size: outputWidth,
                    sourceOrigin: originX,
                    sourceSize: validWidth,
                    sourceImageSize: sourceImageWidth,
                    halo: haloLeft,
                    haloRight: haloRight,
                    quantum: Double(RestoreBlendWeights.fullWeight)
                )
                let sourceIndex = localY * tile.bytesPerRow + (x - outputOriginX) * 4
                let baseWeight = min(horizontal, vertical)
                var weight = baseWeight
                if let maskBase {
                    weight = UInt16((Double(weight) * Double(maskBase[sourceIndex]) / 255).rounded())
                }
                let alpha = weights.blendWeight(
                    pixelX: x,
                    pixelY: y,
                    weight: weight,
                    coverageWeight: maskBase == nil ? nil : baseWeight
                )
                guard alpha > 0 else { continue }
                let destinationIndex = (y * canvas.width + x) * 4
                let inverse = 1 - alpha
                for channel in 0..<3 {
                    let value = Double(tileBase[sourceIndex + channel]) * alpha + Double(destinationBase[destinationIndex + channel]) * inverse
                    destinationBase[destinationIndex + channel] = UInt8(max(0, min(255, value.rounded())))
                }
                destinationBase[destinationIndex + 3] = 255
            }
        }
    }

    fileprivate static func quantizedWeight(
        pixel: Int,
        origin: Int,
        size: Int,
        sourceOrigin: Int,
        sourceSize: Int,
        sourceImageSize: Int,
        halo: Double,
        haloRight: Double? = nil,
        quantum: Double
    ) -> UInt16 {
        let weight = RestoreAIMath.featherWeight(
            pixel: pixel,
            origin: origin,
            size: size,
            sourceOrigin: sourceOrigin,
            sourceSize: sourceSize,
            sourceImageSize: sourceImageSize,
            halo: halo,
            haloRight: haloRight
        )
        return UInt16((min(1, max(0, weight)) * quantum).rounded())
    }

    static func writeJPEG(_ image: CGImage) async throws -> URL {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw RestoreError.fileOperation("照片编码失败")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RestoreError.fileOperation("照片编码失败") }
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(RestoreMath.timestampName(prefix: "restore", ext: "jpg"))
        try (data as Data).write(to: url, options: .atomic)
        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    private static func validate(_ model: MLModel, spec: RestoreModelSpec) throws {
        guard let input = model.modelDescription.inputDescriptionsByName[spec.inputName]?.multiArrayConstraint,
              let output = model.modelDescription.outputDescriptionsByName[spec.outputName]?.multiArrayConstraint,
              input.shape.map({ $0.intValue }) == spec.inputShape,
              input.dataType == spec.dataType.coreMLType,
              output.dataType == spec.dataType.coreMLType,
              spec.outputShape == nil || output.shape.map({ $0.intValue }) == spec.outputShape else {
            throw RestoreError.modelLoadFailed("模型接口与当前版本不匹配")
        }
    }

    static func imageShape(_ array: MLMultiArray) throws -> (width: Int, height: Int) {
        let shape = array.shape.map { $0.intValue }
        var expectedStrides = [Int](repeating: 1, count: shape.count)
        if shape.count > 1 {
            for index in stride(from: shape.count - 2, through: 0, by: -1) {
                expectedStrides[index] = expectedStrides[index + 1] * shape[index + 1]
            }
        }
        guard shape.count == 4, shape[0] == 1, shape[1] == 3,
              array.strides.map({ $0.intValue }) == expectedStrides else {
            throw RestoreError.inferenceFailed("模型输出尺寸或内存布局无效")
        }
        return (shape[3], shape[2])
    }

}

private extension RestoreModelDataType {
    var coreMLType: MLMultiArrayDataType {
        switch self {
        case .float16: return .float16
        case .float32: return .float32
        }
    }
}
