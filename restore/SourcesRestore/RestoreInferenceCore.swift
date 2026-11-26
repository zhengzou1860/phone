import Foundation
import CoreML
import CoreImage
import ImageIO

struct RestoreDecodedImage {
    let image: CGImage
    let source: CIImage
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
        return RestoreDecodedImage(image: image, source: CIImage(cgImage: image), width: image.width, height: image.height)
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

    static func render(_ image: CIImage, extent: CGRect, context: CIContext) throws -> CGImage {
        let cropped = image.cropped(to: extent)
        guard let rendered = context.createCGImage(
            cropped,
            from: extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            throw RestoreError.inferenceFailed("系统无法生成推理图像")
        }
        return rendered
    }

    static func sourceTile(_ source: CIImage, originX: Int, originY: Int, size: Int, context: CIContext) throws -> CGImage {
        let shifted = source
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -Double(originX), y: -Double(originY)))
        return try render(shifted, extent: CGRect(x: 0, y: 0, width: size, height: size), context: context)
    }

    static func maskTile(_ mask: CIImage, originX: Int, originY: Int, size: Int, context: CIContext) throws -> CGImage {
        let shifted = mask.transformed(by: CGAffineTransform(translationX: -Double(originX), y: -Double(originY)))
        return try render(shifted, extent: CGRect(x: 0, y: 0, width: size, height: size), context: context)
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
        tileImage: CGImage,
        originX: Int,
        originY: Int,
        tileSize: Int,
        overlap: Int,
        scale: Double,
        sourceImageWidth: Int,
        sourceImageHeight: Int,
        maskImage: CGImage?
    ) throws {
        let outputWidth = max(1, Int((Double(tileSize) * scale).rounded()))
        let outputHeight = outputWidth
        let tile = try RestorePixelCanvas(width: outputWidth, height: outputHeight)
        tile.context.interpolationQuality = .high
        tile.context.draw(tileImage, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        let maskCanvas = try maskImage.map { image in
            let canvas = try RestorePixelCanvas(width: outputWidth, height: outputHeight)
            canvas.context.interpolationQuality = .high
            canvas.context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
            return canvas
        }
        let destinationBase = canvas.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let tileBase = tile.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let maskBase = maskCanvas?.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let outputOriginX = Int((Double(originX) * scale).rounded())
        let outputOriginY = Int((Double(originY) * scale).rounded())
        let minX = max(0, outputOriginX)
        let maxX = min(canvas.width, outputOriginX + outputWidth)
        let minY = max(0, outputOriginY)
        let maxY = min(canvas.height, outputOriginY + outputHeight)
        let halo = max(1, (Double(overlap) * 2 * scale).rounded())
        guard minX < maxX, minY < maxY else { return }

        for y in minY..<maxY {
            let localY = y - outputOriginY
            let vertical = RestoreAIMath.featherWeight(
                pixel: y,
                origin: outputOriginY,
                size: outputHeight,
                sourceOrigin: originY,
                sourceSize: tileSize,
                sourceImageSize: sourceImageHeight,
                halo: halo
            )
            for x in minX..<maxX {
                let horizontal = RestoreAIMath.featherWeight(
                    pixel: x,
                    origin: outputOriginX,
                    size: outputWidth,
                    sourceOrigin: originX,
                    sourceSize: tileSize,
                    sourceImageSize: sourceImageWidth,
                    halo: halo
                )
                var alpha = min(horizontal, vertical)
                let sourceIndex = localY * tile.bytesPerRow + (x - outputOriginX) * 4
                if let maskBase {
                    alpha *= Double(maskBase[sourceIndex]) / 255
                }
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
