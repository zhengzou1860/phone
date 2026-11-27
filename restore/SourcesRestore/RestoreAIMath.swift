import Foundation

struct RestoreAITile: Equatable {
    let originX: Int
    let originY: Int
    let outputScale: Double
    let overlapLeft: Int
    let overlapRight: Int
    let overlapTop: Int
    let overlapBottom: Int

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
        func origins(for length: Int) -> [Int] {
            guard length > tileSize else { return [0] }
            var result = [0]
            var origin = 0
            while origin + tileSize < length {
                origin = min(origin + step, length - tileSize)
                result.append(origin)
            }
            return result
        }
        let horizontalOrigins = origins(for: width)
        let verticalOrigins = origins(for: height)
        return verticalOrigins.enumerated().flatMap { verticalIndex, y in
            horizontalOrigins.enumerated().map { horizontalIndex, x in
                RestoreAITile(
                    originX: x,
                    originY: y,
                    outputScale: outputScale,
                    overlapLeft: horizontalIndex > 0 ? tileSize - (x - horizontalOrigins[horizontalIndex - 1]) : 0,
                    overlapRight: horizontalIndex + 1 < horizontalOrigins.count ? tileSize - (horizontalOrigins[horizontalIndex + 1] - x) : 0,
                    overlapTop: verticalIndex > 0 ? tileSize - (y - verticalOrigins[verticalIndex - 1]) : 0,
                    overlapBottom: verticalIndex + 1 < verticalOrigins.count ? tileSize - (verticalOrigins[verticalIndex + 1] - y) : 0
                )
            }
        }
    }

    static func featherWeight(
        pixel: Int,
        origin: Int,
        size: Int,
        sourceOrigin: Int,
        sourceSize: Int,
        sourceImageSize: Int,
        halo: Double,
        haloLeft: Double? = nil,
        haloRight: Double? = nil
    ) -> Double {
        guard halo > 0, halo.isFinite else { return 1 }
        let leftHalo = max(1, haloLeft ?? halo)
        let rightHalo = max(1, haloRight ?? halo)
        let left = sourceOrigin <= 0 ? 1 : min(1, max(0, (Double(pixel) - Double(origin)) / leftHalo))
        let right = sourceOrigin + sourceSize >= sourceImageSize ? 1 : min(1, max(0, (Double(origin + size) - Double(pixel)) / rightHalo))
        return min(left, right)
    }

    static let maximumSourceLongEdge = 8192
    static let maximumSourcePixels = 40_000_000
    static let maximumSuperResolutionOutputPixels = 32_000_000

    static func validateSource(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              max(width, height) <= maximumSourceLongEdge,
              Double(width) * Double(height) <= Double(maximumSourcePixels) else {
            throw RestorePreflightError.aiSourceTooLarge
        }
    }

    static func validateOutput(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw RestoreError.invalidDimensions }
        guard Double(width) * Double(height) <= Double(maximumSuperResolutionOutputPixels) else {
            throw RestorePreflightError.aiOutputTooLarge
        }
    }
}
