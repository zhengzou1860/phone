import Foundation
import CoreGraphics
import ImageIO

func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        print("RESTORE-TILE FAIL \(message)")
        exit(1)
    }
    print("RESTORE-TILE PASS \(message)")
}

let width = 585
let height = 790
let bytesPerRow = width * 4
let data = NSMutableData(length: bytesPerRow * height)!
let pixels = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
for y in 0..<height {
    for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = UInt8(x % 251)
        pixels[offset + 1] = UInt8(y % 251)
        pixels[offset + 2] = UInt8((x + y) % 251)
        pixels[offset + 3] = 255
    }
}
guard let provider = CGDataProvider(data: data as CFData),
      let source = CGImage(
    width: width,
    height: height,
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider,
    decode: nil,
    shouldInterpolate: false,
    intent: .defaultIntent
) else {
    fatalError("synthetic source creation failed")
}

func color(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
    let provider = image.dataProvider!
    let bytes = (provider.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
    let offset = y * image.bytesPerRow + x * 4
    return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
}

func colorsClose(_ lhs: (UInt8, UInt8, UInt8), _ rhs: (UInt8, UInt8, UInt8), tolerance: Int = 1) -> Bool {
    abs(Int(lhs.0) - Int(rhs.0)) <= tolerance
        && abs(Int(lhs.1) - Int(rhs.1)) <= tolerance
        && abs(Int(lhs.2) - Int(rhs.2)) <= tolerance
}

func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
    let provider = image.dataProvider!
    let bytes = (provider.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
    return bytes[y * image.bytesPerRow + x * 4 + 3]
}

func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
    let row = width * 4
    let data = NSMutableData(length: row * height)!
    let pixels = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * row + x * 4
            pixels[offset] = red
            pixels[offset + 1] = green
            pixels[offset + 2] = blue
            pixels[offset + 3] = 255
        }
    }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: row,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: data as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

func gradientImage(width: Int, height: Int) -> CGImage {
    let row = width * 4
    let data = NSMutableData(length: row * height)!
    let pixels = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * row + x * 4
            pixels[offset] = UInt8((x * 30) % 251)
            pixels[offset + 1] = UInt8((y * 40) % 251)
            pixels[offset + 2] = UInt8(((x + y) * 20) % 251)
            pixels[offset + 3] = 255
        }
    }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: row,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: data as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

func grayImage(width: Int, height: Int, value: UInt8) -> CGImage {
    let row = ((width + 15) / 16) * 16
    let data = NSMutableData(length: row * height)!
    let pixels = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width { pixels[y * row + x] = value }
    }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: row,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: CGDataProvider(data: data as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

let top = try RestoreInferenceCore.sourceTile(source, originX: 0, originY: 0, size: 384)
expect(color(top, x: 0, y: 0) == (0, 0, 0), "top-left tile starts at the first source pixel")
expect(color(top, x: 100, y: 0).1 == 0, "top tile keeps source rows in top-down order")
let topBytes = (top.dataProvider!.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let topMismatchCount = (0..<384).reduce(0) { count, y in
    count + (0..<384).filter { x in
        let tileOffset = y * top.bytesPerRow + x * 4
        let sourceOffset = y * bytesPerRow + x * 4
        return topBytes[tileOffset] != pixels[sourceOffset]
            || topBytes[tileOffset + 1] != pixels[sourceOffset + 1]
            || topBytes[tileOffset + 2] != pixels[sourceOffset + 2]
    }.count
}
print("RESTORE-TILE DETAIL source-tile mismatches=\(topMismatchCount)/147456")
expect(topMismatchCount == 0, "source tile preserves every valid pixel before inference")

let bottom = try RestoreInferenceCore.sourceTile(source, originX: 201, originY: 406, size: 384)
expect(color(bottom, x: 0, y: 0) == (UInt8(201 % 251), UInt8(406 % 251), UInt8((201 + 406) % 251)), "bottom-right tile starts at its anchored source origin")
expect(color(bottom, x: 383, y: 383) == (UInt8(584 % 251), UInt8(789 % 251), UInt8((584 + 789) % 251)), "bottom-right tile ends at the last source pixel")

let sourceCanvas = try RestorePixelCanvas(width: width, height: height, source: source)
let sourceCanvasImage = try sourceCanvas.makeImage()
expect(color(sourceCanvasImage, x: 0, y: 0) == color(source, x: 0, y: 0), "bitmap canvas keeps the source top row at the top")
expect(color(sourceCanvasImage, x: 584, y: 789) == color(source, x: 584, y: 789), "bitmap canvas keeps the source bottom row at the bottom")

let smallImage = solidImage(width: 300, height: 200, red: 255, green: 0, blue: 0)
let paddedTile = try RestoreInferenceCore.sourceTile(smallImage, originX: 0, originY: 0, size: 384)
let paddedFirst = color(paddedTile, x: 0, y: 0)
let solidRight = color(paddedTile, x: 300, y: 0)
let solidBottom = color(paddedTile, x: 0, y: 200)
let solidCorner = color(paddedTile, x: 300, y: 200)
print("RESTORE-TILE DETAIL solid first=\(paddedFirst) right=\(solidRight) bottom=\(solidBottom) corner=\(solidCorner) alpha=\(alpha(paddedTile, x: 0, y: 0))")
expect(paddedFirst == (255, 0, 0), "small source tile starts at the first source pixel")
expect(color(paddedTile, x: 299, y: 199) == (255, 0, 0), "small source tile keeps its native pixels at native coordinates")
expect(solidRight == (255, 0, 0), "small source tile extends the right edge instead of stretching")
expect(solidBottom == (255, 0, 0), "small source tile extends the bottom edge instead of stretching")
expect(solidCorner == (255, 0, 0), "small source tile extends the corner pixel")
let smallGradient = gradientImage(width: 300, height: 200)
let paddedGradient = try RestoreInferenceCore.sourceTile(smallGradient, originX: 0, originY: 0, size: 384)
expect(colorsClose(color(paddedGradient, x: 0, y: 0), color(smallGradient, x: 0, y: 0)), "small source tile keeps its top-left pixel at the tile origin")
expect(colorsClose(color(paddedGradient, x: 299, y: 199), color(smallGradient, x: 299, y: 199)), "small source tile keeps its bottom-right pixel at native coordinates")
let rightPadding = color(paddedGradient, x: 300, y: 100)
let rightPaddingSource = color(smallGradient, x: 299, y: 100)
let bottomPadding = color(paddedGradient, x: 100, y: 200)
let bottomPaddingSource = color(smallGradient, x: 100, y: 199)
let cornerPadding = color(paddedGradient, x: 300, y: 200)
let cornerPaddingSource = color(smallGradient, x: 299, y: 199)
print("RESTORE-TILE DETAIL padding right=\(rightPadding)/\(rightPaddingSource) bottom=\(bottomPadding)/\(bottomPaddingSource) corner=\(cornerPadding)/\(cornerPaddingSource)")
expect(colorsClose(rightPadding, rightPaddingSource), "right padding replicates each source row edge")
expect(colorsClose(bottomPadding, bottomPaddingSource), "bottom padding replicates each source column edge")
expect(colorsClose(cornerPadding, cornerPaddingSource), "corner padding replicates the bottom-right source pixel")

let modelScale = 2
let validPrediction = gradientImage(width: 300 * modelScale, height: 200 * modelScale)
let modelPaddingContext = CGContext(
    data: nil,
    width: 768,
    height: 768,
    bitsPerComponent: 8,
    bytesPerRow: 768 * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
)!
modelPaddingContext.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
modelPaddingContext.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
modelPaddingContext.draw(validPrediction, in: CGRect(x: 0, y: 768 - 400, width: 600, height: 400))
let modelPaddingImage = modelPaddingContext.makeImage()!
expect(colorsClose(color(modelPaddingImage, x: 0, y: 0), color(validPrediction, x: 0, y: 0)), "model padding fixture keeps valid prediction at the top-left")
let smallModelCanvas = try RestorePixelCanvas(width: 600, height: 400)
try RestoreInferenceCore.blend(
    canvas: smallModelCanvas,
    weights: try RestoreBlendWeights(width: 600, height: 400),
    tileImage: modelPaddingImage,
    originX: 0,
    originY: 0,
    tileSize: 384,
    overlap: 32,
    sourceImageWidth: 300,
    sourceImageHeight: 200,
    maskImage: nil
)
let smallModelImage = try smallModelCanvas.makeImage()
let smallModelFirst = color(smallModelImage, x: 0, y: 0)
let smallModelLast = color(smallModelImage, x: 599, y: 399)
let smallModelMiddle = color(smallModelImage, x: 250, y: 200)
print("RESTORE-TILE DETAIL model first=\(smallModelFirst)/\(color(validPrediction, x: 0, y: 0)) last=\(smallModelLast)/\(color(validPrediction, x: 599, y: 399)) middle=\(smallModelMiddle)/\(color(validPrediction, x: 250, y: 200))")
expect(colorsClose(smallModelFirst, color(validPrediction, x: 0, y: 0)), "small 2x model output starts at the first valid source pixel")
expect(colorsClose(smallModelLast, color(validPrediction, x: 599, y: 399)), "small 2x model output excludes padding instead of squeezing it into the photo")
expect(colorsClose(smallModelMiddle, color(validPrediction, x: 250, y: 200)), "small 2x model output keeps valid content at native model coordinates")

let edgePredictionImage = solidImage(width: 768, height: 768, red: 255, green: 0, blue: 0)
let edgePredictionLast = color(edgePredictionImage, x: 767, y: 767)
let edgeCroppedPrediction = edgePredictionImage.cropping(to: CGRect(x: 0, y: 0, width: 768, height: 768))!
let edgeCroppedLast = color(edgeCroppedPrediction, x: 767, y: 767)
let edgeProbeContext = CGContext(
    data: nil,
    width: 768,
    height: 768,
    bitsPerComponent: 8,
    bytesPerRow: 768 * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
)!
edgeProbeContext.draw(edgeCroppedPrediction, in: CGRect(x: 0, y: 0, width: 768, height: 768))
let edgeProbeLast = color(edgeProbeContext.makeImage()!, x: 767, y: 767)
let edgeModelCanvas = try RestorePixelCanvas(width: 585 * modelScale, height: 790 * modelScale)
try RestoreInferenceCore.blend(
    canvas: edgeModelCanvas,
    weights: try RestoreBlendWeights(width: 585 * modelScale, height: 790 * modelScale),
    tileImage: edgePredictionImage,
    originX: 201,
    originY: 406,
    tileSize: 384,
    overlap: 32,
    overlapLeft: 183,
    overlapTop: 346,
    sourceImageWidth: 585,
    sourceImageHeight: 790,
    maskImage: nil
)
let edgeModelImage = try edgeModelCanvas.makeImage()
let edgeModelLast = color(edgeModelImage, x: 585 * modelScale - 1, y: 790 * modelScale - 1)
let edgeDirectOffset = (790 * modelScale - 1) * edgeModelCanvas.bytesPerRow + (585 * modelScale - 1) * 4
let edgeDirectBytes = edgeModelCanvas.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
let edgeDirectLast = (edgeDirectBytes[edgeDirectOffset], edgeDirectBytes[edgeDirectOffset + 1], edgeDirectBytes[edgeDirectOffset + 2])
print("RESTORE-TILE DETAIL edge prediction=\(edgePredictionLast) cropped=\(edgeCroppedLast) probe=\(edgeProbeLast) direct=\(edgeDirectLast) image=\(edgeModelLast) row=\(edgeModelImage.bytesPerRow) canvasRow=\(edgeModelCanvas.bytesPerRow)")
expect(edgeModelLast == (255, 0, 0), "edge-anchored 2x model output maps only valid pixels to the photo boundary")

let smallMask = solidImage(width: 300, height: 200, red: 255, green: 255, blue: 255)
let paddedMask = try RestoreInferenceCore.maskTile(smallMask, originX: 0, originY: 0, size: 384)
expect(alpha(paddedMask, x: 0, y: 0) == 255 && alpha(paddedMask, x: 0, y: 383) == 0, "small mask tile keeps valid pixels at the top and pads the bottom")
expect(alpha(paddedMask, x: 299, y: 199) == 255 && alpha(paddedMask, x: 300, y: 0) == 0, "small mask tile pads with transparent pixels")
let grayMaskTile = try RestoreInferenceCore.maskTile(grayImage(width: 300, height: 200, value: 128), originX: 0, originY: 0, size: 384)
let grayMaskPixel = color(grayMaskTile, x: 299, y: 199)
expect(grayMaskPixel.0 >= 127 && grayMaskPixel.0 <= 129 && grayMaskPixel.1 == grayMaskPixel.0 && grayMaskPixel.2 == grayMaskPixel.0 && alpha(grayMaskTile, x: 299, y: 199) == 255, "grayscale repair mask keeps its intensity in the RGB tile")

let smallInpaintCanvas = try RestorePixelCanvas(width: 300, height: 200)
let smallInpaintWeights = try RestoreBlendWeights(width: 300, height: 200)
try RestoreInferenceCore.blend(
    canvas: smallInpaintCanvas,
    weights: smallInpaintWeights,
    tileImage: solidImage(width: 512, height: 512, red: 255, green: 0, blue: 0),
    originX: 0,
    originY: 0,
    tileSize: 512,
    overlap: 32,
    sourceImageWidth: 300,
    sourceImageHeight: 200,
    maskImage: solidImage(width: 512, height: 512, red: 255, green: 255, blue: 255)
)
try smallInpaintWeights.composite(
    smallInpaintCanvas,
    over: solidImage(width: 300, height: 200, red: 100, green: 100, blue: 100)
)
let smallInpaintImage = try smallInpaintCanvas.makeImage()
expect(color(smallInpaintImage, x: 299, y: 199) == (255, 0, 0), "small inpaint output and mask crop their padded regions together")

let canvas = try RestorePixelCanvas(width: width, height: height)
let tiles = RestoreAIMath.tilePlan(width: width, height: height, tileSize: 384, overlap: 8, outputScale: 1)
let weights = try RestoreBlendWeights(width: width, height: height)
expect(tiles.count == 6, "pixel test uses the exact six-tile phone geometry")
for tile in tiles {
    let tileImage = try RestoreInferenceCore.sourceTile(source, originX: tile.originX, originY: tile.originY, size: 384)
    try RestoreInferenceCore.blend(
        canvas: canvas,
        weights: weights,
        tileImage: tileImage,
        originX: tile.originX,
        originY: tile.originY,
        tileSize: 384,
        overlap: 8,
        overlapLeft: tile.overlapLeft,
        overlapRight: tile.overlapRight,
        overlapTop: tile.overlapTop,
        overlapBottom: tile.overlapBottom,
        sourceImageWidth: width,
        sourceImageHeight: height,
        maskImage: nil
    )
}
let blended = try canvas.makeImage()
expect(color(blended, x: 0, y: 0) == color(source, x: 0, y: 0), "top-left photo edge is not blended into a black canvas")
expect(color(blended, x: 584, y: 789) == color(source, x: 584, y: 789), "bottom-right photo edge is not blended into a black canvas")
expect(colorsClose(color(blended, x: 250, y: 430), color(source, x: 250, y: 430)), "blend writes tile rows to the same top-down destination rows")
expect(colorsClose(color(blended, x: 250, y: 500), color(source, x: 250, y: 500)), "lower photo content is not moved to the upper half")
let blendedProvider = blended.dataProvider!
let blendedBytes = (blendedProvider.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let sourceBytes = pixels
var mismatchCount = 0
var maximumDelta = 0
var firstMismatch: (x: Int, y: Int, actual: (UInt8, UInt8, UInt8), expected: (UInt8, UInt8, UInt8))?
var mismatchBounds = (minX: width, minY: height, maxX: -1, maxY: -1)
for y in 0..<height {
    for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        let actual = (blendedBytes[offset], blendedBytes[offset + 1], blendedBytes[offset + 2])
        let expected = (sourceBytes[offset], sourceBytes[offset + 1], sourceBytes[offset + 2])
        let delta = max(
            abs(Int(actual.0) - Int(expected.0)),
            abs(Int(actual.1) - Int(expected.1)),
            abs(Int(actual.2) - Int(expected.2))
        )
        maximumDelta = max(maximumDelta, delta)
        guard delta > 1 else { continue }
        mismatchCount += 1
        if firstMismatch == nil { firstMismatch = (x, y, actual, expected) }
        mismatchBounds.minX = min(mismatchBounds.minX, x)
        mismatchBounds.minY = min(mismatchBounds.minY, y)
        mismatchBounds.maxX = max(mismatchBounds.maxX, x)
        mismatchBounds.maxY = max(mismatchBounds.maxY, y)
    }
}
print("RESTORE-TILE DETAIL reconstruction mismatches=\(mismatchCount)/\(width * height) maxDelta=\(maximumDelta) first=\(String(describing: firstMismatch)) bounds=\(mismatchBounds)")
expect(mismatchCount == 0, "all six tiles reconstruct every source pixel without gaps or dark seams")

let scaledCanvas = try RestorePixelCanvas(width: width * 2, height: height * 2)
let scaledWeights = try RestoreBlendWeights(width: width * 2, height: height * 2)
for tile in tiles {
    let tileImage = try RestoreInferenceCore.sourceTile(source, originX: tile.originX, originY: tile.originY, size: 384)
    try RestoreInferenceCore.blend(
        canvas: scaledCanvas,
        weights: scaledWeights,
        tileImage: tileImage,
        originX: tile.originX,
        originY: tile.originY,
        tileSize: 384,
        overlap: 8,
        overlapLeft: tile.overlapLeft,
        overlapRight: tile.overlapRight,
        overlapTop: tile.overlapTop,
        overlapBottom: tile.overlapBottom,
        sourceImageWidth: width,
        sourceImageHeight: height,
        maskImage: nil
    )
}
let scaled = try scaledCanvas.makeImage()
expect(color(scaled, x: 0, y: 0).1 <= 2, "scaled output keeps the photo top at the top")
expect(color(scaled, x: width * 2 - 1, y: height * 2 - 1).1 >= 34, "scaled output keeps the photo bottom at the bottom")

let seamSide = 800
let seamTiles = RestoreAIMath.tilePlan(width: seamSide, height: seamSide, tileSize: 384, overlap: 8, outputScale: 1)
func seamColor(_ tile: RestoreAITile) -> (UInt8, UInt8, UInt8) {
    switch (tile.originX, tile.originY) {
    case (0, 0), (0, 368): return (255, 0, 0)
    case (368, 0), (368, 368): return (0, 255, 0)
    case (416, 368): return (0, 0, 255)
    case (368, 416): return (255, 255, 0)
    case (416, 416): return (255, 0, 255)
    default: return (255, 255, 255)
    }
}
let seamCanvas = try RestorePixelCanvas(width: seamSide, height: seamSide)
let seamWeights = try RestoreBlendWeights(width: seamSide, height: seamSide)
for tile in seamTiles {
    let value = seamColor(tile)
    try RestoreInferenceCore.blend(
        canvas: seamCanvas,
        weights: seamWeights,
        tileImage: solidImage(width: 384, height: 384, red: value.0, green: value.1, blue: value.2),
        originX: tile.originX,
        originY: tile.originY,
        tileSize: 384,
        overlap: 8,
        overlapLeft: tile.overlapLeft,
        overlapRight: tile.overlapRight,
        overlapTop: tile.overlapTop,
        overlapBottom: tile.overlapBottom,
        sourceImageWidth: seamSide,
        sourceImageHeight: seamSide,
        maskImage: nil
    )
}
let seamImage = try seamCanvas.makeImage()
expect(color(seamImage, x: 10, y: 10) == (255, 0, 0), "distinct-color tile keeps the top-left edge at full strength")
expect(color(seamImage, x: 799, y: 799) == (255, 0, 255), "distinct-color tile keeps the bottom-right edge at full strength")
let pair = color(seamImage, x: 370, y: 370)
expect(abs(Int(pair.0) - 204) <= 1 && abs(Int(pair.1) - 51) <= 1 && pair.2 == 0, "regular overlap uses the full 16px complementary feather")
let crossing = color(seamImage, x: 420, y: 420)
expect(abs(Int(crossing.0) - 6) <= 2 && abs(Int(crossing.1) - 249) <= 2 && abs(Int(crossing.2) - 6) <= 2, "four-tile crossing uses actual neighbor overlaps in the normalized average")

let reversedCanvas = try RestorePixelCanvas(width: seamSide, height: seamSide)
let reversedWeights = try RestoreBlendWeights(width: seamSide, height: seamSide)
for tile in seamTiles.reversed() {
    let value = seamColor(tile)
    try RestoreInferenceCore.blend(
        canvas: reversedCanvas,
        weights: reversedWeights,
        tileImage: solidImage(width: 384, height: 384, red: value.0, green: value.1, blue: value.2),
        originX: tile.originX,
        originY: tile.originY,
        tileSize: 384,
        overlap: 8,
        overlapLeft: tile.overlapLeft,
        overlapRight: tile.overlapRight,
        overlapTop: tile.overlapTop,
        overlapBottom: tile.overlapBottom,
        sourceImageWidth: seamSide,
        sourceImageHeight: seamSide,
        maskImage: nil
    )
}
let reversedImage = try reversedCanvas.makeImage()
let seamBytes = (seamImage.dataProvider!.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let reversedBytes = (reversedImage.dataProvider!.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let orderIndependent = (0..<seamSide).allSatisfy { y in
    (0..<seamSide).allSatisfy { x in
        let offset = y * seamImage.bytesPerRow + x * 4
        return (0..<3).allSatisfy { channel in
            abs(Int(seamBytes[offset + channel]) - Int(reversedBytes[offset + channel])) <= 2
        }
    }
}
expect(orderIndependent, "distinct-color tile blending is independent of processing order")

let nineSide = 760
let nineTiles = RestoreAIMath.tilePlan(width: nineSide, height: nineSide, tileSize: 384, overlap: 8, outputScale: 1)
let nineColors: [(UInt8, UInt8, UInt8)] = [
    (255, 0, 0), (0, 255, 0), (0, 0, 255),
    (255, 255, 0), (255, 0, 255), (0, 255, 255),
    (255, 255, 255), (128, 0, 128), (0, 128, 128)
]
func nineImage(order: [RestoreAITile]) throws -> CGImage {
    let canvas = try RestorePixelCanvas(width: nineSide, height: nineSide)
    let weights = try RestoreBlendWeights(width: nineSide, height: nineSide)
    for tile in order {
        let value = nineColors[nineTiles.firstIndex(of: tile)!]
        try RestoreInferenceCore.blend(
            canvas: canvas,
            weights: weights,
            tileImage: solidImage(width: 384, height: 384, red: value.0, green: value.1, blue: value.2),
            originX: tile.originX,
            originY: tile.originY,
            tileSize: 384,
            overlap: 8,
            overlapLeft: tile.overlapLeft,
            overlapRight: tile.overlapRight,
            overlapTop: tile.overlapTop,
            overlapBottom: tile.overlapBottom,
            sourceImageWidth: nineSide,
            sourceImageHeight: nineSide,
            maskImage: nil
        )
    }
    return try canvas.makeImage()
}
let nineForward = try nineImage(order: nineTiles)
let nineReverse = try nineImage(order: Array(nineTiles.reversed()))
let nineForwardBytes = (nineForward.dataProvider!.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let nineReverseBytes = (nineReverse.dataProvider!.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let nineOrderIndependent = (0..<nineSide).allSatisfy { y in
    (0..<nineSide).allSatisfy { x in
        let offset = y * nineForward.bytesPerRow + x * 4
        return (0..<3).allSatisfy { channel in
            abs(Int(nineForwardBytes[offset + channel]) - Int(nineReverseBytes[offset + channel])) <= 2
        }
    }
}
expect(nineOrderIndependent, "nine-tile large-overlap crossings stay within 8-bit rounding tolerance")

let largeOverlapWidth = 585
let largeOverlapTiles = RestoreAIMath.tilePlan(width: largeOverlapWidth, height: 100, tileSize: 384, overlap: 8, outputScale: 1)
let largeOverlapCanvas = try RestorePixelCanvas(width: largeOverlapWidth, height: 100)
let largeOverlapWeights = try RestoreBlendWeights(width: largeOverlapWidth, height: 100)
for tile in largeOverlapTiles {
    let first = tile.originX == 0
    try RestoreInferenceCore.blend(
        canvas: largeOverlapCanvas,
        weights: largeOverlapWeights,
        tileImage: solidImage(width: 384, height: 384, red: first ? 255 : 0, green: first ? 0 : 255, blue: 0),
        originX: tile.originX,
        originY: tile.originY,
        tileSize: 384,
        overlap: 8,
        overlapLeft: tile.overlapLeft,
        overlapRight: tile.overlapRight,
        overlapTop: tile.overlapTop,
        overlapBottom: tile.overlapBottom,
        sourceImageWidth: largeOverlapWidth,
        sourceImageHeight: 100,
        maskImage: nil
    )
}
let largeOverlapImage = try largeOverlapCanvas.makeImage()
let largeOverlap = color(largeOverlapImage, x: 220, y: 50)
expect(abs(Int(largeOverlap.0) - 229) <= 2 && abs(Int(largeOverlap.1) - 26) <= 2, "edge-anchored 183px overlap is feathered across its actual width")

let maskWidth = 800
let maskHeight = 100
let maskTiles = RestoreAIMath.tilePlan(width: maskWidth, height: maskHeight, tileSize: 384, overlap: 8, outputScale: 1)
let maskedCanvas = try RestorePixelCanvas(width: maskWidth, height: maskHeight)
let maskedWeights = try RestoreBlendWeights(width: maskWidth, height: maskHeight)
for tile in maskTiles {
    let first = tile.originX == 0
    try RestoreInferenceCore.blend(
        canvas: maskedCanvas,
        weights: maskedWeights,
        tileImage: solidImage(width: 384, height: 384, red: first ? 255 : 0, green: first ? 0 : 255, blue: 0),
        originX: tile.originX,
        originY: tile.originY,
        tileSize: 384,
        overlap: 8,
        overlapLeft: tile.overlapLeft,
        overlapRight: tile.overlapRight,
        overlapTop: tile.overlapTop,
        overlapBottom: tile.overlapBottom,
        sourceImageWidth: maskWidth,
        sourceImageHeight: maskHeight,
        maskImage: solidImage(width: 384, height: 384, red: first ? 128 : 255, green: 0, blue: 0)
    )
}
try maskedWeights.composite(
    maskedCanvas,
    over: solidImage(width: maskWidth, height: maskHeight, red: 100, green: 100, blue: 100)
)
let maskedImage = try maskedCanvas.makeImage()
let partialEdge = color(maskedImage, x: 10, y: 50)
expect(abs(Int(partialEdge.0) - 178) <= 2 && abs(Int(partialEdge.1) - 50) <= 2 && abs(Int(partialEdge.2) - 50) <= 2, "partial inpaint mask keeps the unmatched source weight")
let partialOverlap = color(maskedImage, x: 370, y: 50)
expect(abs(Int(partialOverlap.0) - 156) <= 2 && abs(Int(partialOverlap.1) - 76) <= 2 && abs(Int(partialOverlap.2) - 44) <= 2, "partial inpaint weights include the original image in the normalized average")

let crossingMaskCanvas = try RestorePixelCanvas(width: seamSide, height: seamSide)
let crossingMaskWeights = try RestoreBlendWeights(width: seamSide, height: seamSide)
for tile in seamTiles {
    let value = seamColor(tile)
    try RestoreInferenceCore.blend(
        canvas: crossingMaskCanvas,
        weights: crossingMaskWeights,
        tileImage: solidImage(width: 384, height: 384, red: value.0, green: value.1, blue: value.2),
        originX: tile.originX,
        originY: tile.originY,
        tileSize: 384,
        overlap: 8,
        overlapLeft: tile.overlapLeft,
        overlapRight: tile.overlapRight,
        overlapTop: tile.overlapTop,
        overlapBottom: tile.overlapBottom,
        sourceImageWidth: seamSide,
        sourceImageHeight: seamSide,
        maskImage: solidImage(width: 384, height: 384, red: 128, green: 0, blue: 0)
    )
}
try crossingMaskWeights.composite(
    crossingMaskCanvas,
    over: solidImage(width: seamSide, height: seamSide, red: 100, green: 100, blue: 100)
)
let crossingMaskImage = try crossingMaskCanvas.makeImage()
let crossingMask = color(crossingMaskImage, x: 420, y: 420)
expect(abs(Int(crossingMask.0) - 53) <= 3 && abs(Int(crossingMask.1) - 175) <= 3 && abs(Int(crossingMask.2) - 53) <= 3, "2D masked overlap normalizes coverage by total feather weight")

let orientationSource = gradientImage(width: 13, height: 9)
let orientationCanvas = try RestorePixelCanvas(width: 13, height: 9)
let orientationWeights = try RestoreBlendWeights(width: 13, height: 9)
try orientationWeights.composite(orientationCanvas, over: orientationSource)
let orientationImage = try orientationCanvas.makeImage()
let expectedOrientation = try RestorePixelCanvas(width: 13, height: 9, source: orientationSource).makeImage()
let orientationBytes = (orientationImage.dataProvider!.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let expectedOrientationBytes = (expectedOrientation.dataProvider!.data! as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let orientationPreserved = (0..<9).allSatisfy { y in
    (0..<13).allSatisfy { x in
        let offset = y * orientationImage.bytesPerRow + x * 4
        return (0..<3).allSatisfy { channel in
            orientationBytes[offset + channel] == expectedOrientationBytes[offset + channel]
        }
    }
}
expect(orientationPreserved, "masked compositor scales the original top-down without vertical flipping")

let fractionalSource = solidImage(width: 7, height: 5, red: 255, green: 32, blue: 16)
let fractionalTiles = RestoreAIMath.tilePlan(width: 7, height: 5, tileSize: 4, overlap: 1, outputScale: 1)
let fractionalCanvas = try RestorePixelCanvas(width: 10, height: 8)
let fractionalWeights = try RestoreBlendWeights(width: 10, height: 8)
for tile in fractionalTiles {
    try RestoreInferenceCore.blend(
        canvas: fractionalCanvas,
        weights: fractionalWeights,
        tileImage: try RestoreInferenceCore.sourceTile(fractionalSource, originX: tile.originX, originY: tile.originY, size: 4),
        originX: tile.originX,
        originY: tile.originY,
        tileSize: 4,
        overlap: 1,
        overlapLeft: tile.overlapLeft,
        overlapRight: tile.overlapRight,
        overlapTop: tile.overlapTop,
        overlapBottom: tile.overlapBottom,
        sourceImageWidth: 7,
        sourceImageHeight: 5,
        maskImage: nil
    )
}
let fractionalImage = try fractionalCanvas.makeImage()
let fractionalCovered = (0..<8).allSatisfy { y in
    (0..<10).allSatisfy { x in
        alpha(fractionalImage, x: x, y: y) == 255 && color(fractionalImage, x: x, y: y) == (255, 32, 16)
    }
}
expect(fractionalCovered, "fractional scaling covers every output pixel without a black final row or column")

print("RESTORE-TILE-VERDICT PASS")
