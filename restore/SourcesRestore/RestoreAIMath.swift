import Foundation

struct RestoreAITile: Equatable {
    let originX: Int
    let originY: Int
    let outputScale: Double

    var sourceMinX: Int { originX }
    var sourceMinY: Int { originY }
}

enum RestoreAIMath {
    static func tilePlan(
        width: Int,
        height: Int,
        tileSize: Int,
        overlap: Int,
        outputScale: Double
    ) -> [RestoreAITile] {
        guard width > 0, height > 0, tileSize > overlap * 2, overlap >= 0, outputScale.isFinite, outputScale > 0 else {
            return []
        }
        let step = tileSize - overlap * 2
        var tiles: [RestoreAITile] = []
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                tiles.append(RestoreAITile(originX: x - overlap, originY: y - overlap, outputScale: outputScale))
                x += step
            }
            y += step
        }
        return tiles
    }

    static func featherWeight(
        pixel: Int,
        origin: Int,
        size: Int,
        sourceOrigin: Int,
        sourceSize: Int,
        sourceImageSize: Int,
        halo: Double
    ) -> Double {
        guard halo > 0, halo.isFinite else { return 1 }
        let left = sourceOrigin < 0 ? 1 : min(1, max(0, (Double(pixel) - Double(origin)) / halo))
        let right = sourceOrigin + sourceSize > sourceImageSize ? 1 : min(1, max(0, (Double(origin + size) - Double(pixel)) / halo))
        return min(left, right)
    }

    static let maximumSourceLongEdge = 8192
    static let maximumSourcePixels = 40_000_000
    static let maximumSuperResolutionOutputPixels = 32_000_000
    static let maximumInpaintingOutputPixels = 16_000_000

    static func validateSource(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              max(width, height) <= maximumSourceLongEdge,
              Double(width) * Double(height) <= Double(maximumSourcePixels) else {
            throw RestorePreflightError.aiSourceTooLarge
        }
    }

    static func validateOutput(width: Int, height: Int, isSuperResolution: Bool) throws {
        guard width > 0, height > 0 else { throw RestoreError.invalidDimensions }
        let limit = isSuperResolution ? maximumSuperResolutionOutputPixels : maximumInpaintingOutputPixels
        guard Double(width) * Double(height) <= Double(limit) else {
            throw RestorePreflightError.aiOutputTooLarge(isSuperResolution: isSuperResolution)
        }
    }
}
