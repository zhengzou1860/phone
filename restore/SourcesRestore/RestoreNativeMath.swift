import Foundation

struct RestoreNativeTile {
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    let validWidth: Int
    let validHeight: Int
    let overlapLeft: Int
    let overlapRight: Int
    let overlapTop: Int
    let overlapBottom: Int
}

enum RestoreNativeMath {
    static func tilePlan(width: Int, height: Int, maximumWidth: Int, maximumHeight: Int, overlap: Int) -> [RestoreNativeTile] {
        guard width > 0, height > 0, maximumWidth > 0, maximumHeight > 0,
              overlap >= 0, overlap * 3 < min(maximumWidth, maximumHeight) else { return [] }
        let tileWidth = min(width, maximumWidth)
        let tileHeight = min(height, maximumHeight)
        func origins(for length: Int, tileSize: Int) -> [Int] {
            guard length > tileSize else { return [0] }
            let step = tileSize - overlap
            var result = [0]
            var origin = 0
            while origin + tileSize < length {
                origin = min(origin + step, length - tileSize)
                result.append(origin)
            }
            return result
        }
        let columns = origins(for: width, tileSize: tileWidth)
        let rows = origins(for: height, tileSize: tileHeight)
        return rows.enumerated().flatMap { rowIndex, y in
            columns.enumerated().map { columnIndex, x in
                RestoreNativeTile(
                    originX: x,
                    originY: y,
                    width: tileWidth,
                    height: tileHeight,
                    validWidth: min(tileWidth, width - x),
                    validHeight: min(tileHeight, height - y),
                    overlapLeft: columnIndex > 0 ? tileWidth - (x - columns[columnIndex - 1]) : 0,
                    overlapRight: columnIndex + 1 < columns.count ? tileWidth - (columns[columnIndex + 1] - x) : 0,
                    overlapTop: rowIndex > 0 ? tileHeight - (y - rows[rowIndex - 1]) : 0,
                    overlapBottom: rowIndex + 1 < rows.count ? tileHeight - (rows[rowIndex + 1] - y) : 0
                )
            }
        }
    }
}
