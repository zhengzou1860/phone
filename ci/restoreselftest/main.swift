import Foundation

func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        print("RESTORE-CASE FAIL \(message)")
        exit(1)
    }
    print("RESTORE-CASE PASS \(message)")
}

let capped = RestoreMath.fittedSize(width: 4032, height: 3024, scale: 2, maxLongEdge: 4096)
expect(capped.width == 4096 && capped.height == 3072, "12MP landscape capped at 4096 with aspect ratio")

let portrait = RestoreMath.fittedSize(width: 3024, height: 4032, scale: 2, maxLongEdge: 4096)
expect(portrait.width == 3072 && portrait.height == 4096, "portrait output remains portrait")

let even = RestoreMath.fittedSize(width: 1919, height: 1079, scale: 1, maxLongEdge: 3840)
expect(even.width == 1918 && even.height == 1078, "video dimensions are even")

let actual = RestoreMath.actualScale(width: 4032, height: 3024, requested: 2, maxLongEdge: 4096)
expect(abs(actual - 4096.0 / 4032.0) < 0.00001, "actual scale reflects memory cap")

let memory = RestoreMath.estimatedMemoryMB(width: 4096, height: 3072)
expect(abs(memory - 96) < 0.001, "working memory estimate is deterministic")

func expectPreflightError(_ body: () throws -> Void, _ message: String) {
    do {
        try body()
        expect(false, "preflight should reject \(message)")
    } catch {
        expect(error.localizedDescription.contains(message), "preflight rejection explains \(message)")
    }
}

try RestorePreflight.validate(width: 3840, height: 2160, duration: 900, isVideo: true)
expect(true, "4K video at the 15 minute boundary is accepted")
try RestorePreflight.validate(width: 4000, height: 3000, duration: 60, isVideo: true)
expect(true, "video at the exact 12MP boundary is accepted")
expectPreflightError({ try RestorePreflight.validate(width: 0, height: 1080, duration: 60, isVideo: true) }, "尺寸无效")
expectPreflightError({ try RestorePreflight.validate(width: 1920, height: 1080, duration: 901, isVideo: true) }, "15 分钟")
expectPreflightError({ try RestorePreflight.validate(width: 4097, height: 2160, duration: 60, isVideo: true) }, "4K")
expectPreflightError({ try RestorePreflight.validate(width: 4000, height: 3001, duration: 60, isVideo: true) }, "4K")
expectPreflightError({ try RestorePreflight.validate(width: 1920, height: 1080, duration: .nan, isVideo: true) }, "时长")

let megabyte: Int64 = 1024 * 1024
let upscaleEstimate = RestorePreflight.estimatedOutputBytes(
    sourceBytes: 100 * megabyte,
    sourceWidth: 1920,
    sourceHeight: 1080,
    outputWidth: 3840,
    outputHeight: 2160
)
expect(upscaleEstimate == 500 * megabyte, "4K output estimate scales source bytes by pixel ratio and headroom")
let upscaleRequired = RestorePreflight.requiredExportBytes(
    sourceBytes: 100 * megabyte,
    sourceWidth: 1920,
    sourceHeight: 1080,
    outputWidth: 3840,
    outputHeight: 2160
)
expect(upscaleRequired == 1012 * megabyte, "export preflight reserves 512 MB safety space")
let downscaleEstimate = RestorePreflight.estimatedOutputBytes(
    sourceBytes: 100 * megabyte,
    sourceWidth: 4096,
    sourceHeight: 2160,
    outputWidth: 3840,
    outputHeight: 2160
)
expect(downscaleEstimate == 122_880_000, "downscaled output estimate uses the actual pixel ratio")
expect(RestorePreflight.estimatedOutputBytes(
    sourceBytes: Int64.max,
    sourceWidth: 1,
    sourceHeight: 1,
    outputWidth: 4096,
    outputHeight: 4096
) == Int64.max / 2, "output estimate saturates instead of overflowing")
expect(RestorePreflight.requiredImportBytes(sourceBytes: Int64.max) == Int64.max, "required space saturates instead of overflowing")
try RestorePreflight.validateSpace(required: upscaleRequired, available: upscaleRequired)
expectPreflightError({ try RestorePreflight.validateSpace(required: upscaleRequired, available: upscaleRequired - 1) }, "可用空间不足")
expect(RestorePreflight.requiredImportBytes(sourceBytes: 1024 * megabyte) == 1536 * megabyte, "import preflight includes source copy and safety space")

let small = RestoreMath.fittedSize(width: 640, height: 480, scale: 1.5, maxLongEdge: 3840)
expect(small.width == 960 && small.height == 720, "1.5x upscale keeps exact aspect ratio")

let pcEndpoint = "192.168.1.8:8719/report"
expect(RestorePCTransport.normalizedEndpoint(pcEndpoint) == "http://192.168.1.8:8719/report", "PC endpoint gets an HTTP scheme automatically")
expect(RestorePCTransport.route("/ping", endpoint: pcEndpoint)?.path == "/ping", "connection test uses the ping route")
expect(RestorePCTransport.route("/upload", endpoint: "https://pc.local:8719/report?old=1")?.scheme == "https", "explicit HTTPS endpoint is preserved")
expect(RestorePCTransport.normalizedEndpoint("ftp://192.168.1.8:8719/report") == nil, "unsupported PC endpoint scheme is rejected")
let encodedName = RestorePCTransport.encodedFilename("../../my clip.mov")
expect(!encodedName.contains("/") && encodedName.contains("%20"), "upload filename header cannot introduce path separators")
let timeoutMessage = RestorePCTransport.userMessage(for: URLError(.timedOut))
expect(timeoutMessage.contains("同一 Wi-Fi") && timeoutMessage.contains("start_hirestore.bat"), "timeout diagnostic explains receiver and firewall checks")
let authMessage = RestorePCTransport.userMessage(for: RestorePCError.http(401, "unauthorized"))
expect(authMessage.contains("上传密钥不一致"), "unauthorized diagnostic explains token mismatch")

let manyLines = (0..<1005).map { "line \($0)" }
expect(RestoreJournal.compact(manyLines).count == 1000, "runtime journal keeps only the latest 1000 lines")
let largeLines = (0..<1000).map { _ in String(repeating: "x", count: 1000) }
let compacted = RestoreJournal.compact(largeLines)
expect(compacted.joined(separator: "\n").utf8.count <= 512 * 1024, "runtime journal respects its byte cap")

let singleAITile = RestoreAIMath.tilePlan(width: 300, height: 200, tileSize: 384, overlap: 8, outputScale: 1)
expect(singleAITile.count == 1 && singleAITile[0].originX == -8 && singleAITile[0].originY == -8, "small AI image uses one padded tile")
let edgeAITiles = RestoreAIMath.tilePlan(width: 384, height: 384, tileSize: 384, overlap: 8, outputScale: 1)
expect(edgeAITiles.count == 4 && edgeAITiles.contains { $0.originX == 360 }, "AI tile grid covers both edges with overlap")
let upperTileOffset = RestoreAIMath.sourceTileVerticalOffset(sourceHeight: 790, originY: 360, size: 384)
expect(upperTileOffset == 46 && 790 - (upperTileOffset + 384) == 360, "AI tiles select the correct photo rows from Core Image bottom-left coordinates")
let paddedTileOffset = RestoreAIMath.sourceTileVerticalOffset(sourceHeight: 790, originY: -8, size: 384)
expect(paddedTileOffset == 414 && 790 - paddedTileOffset == 376, "AI padded tiles select the top edge without shifting content")
let overlapWeightsSum = (360..<376).allSatisfy { pixel in
    let first = RestoreAIMath.featherWeight(pixel: pixel, origin: -8, size: 384, sourceOrigin: -8, sourceSize: 384, sourceImageSize: 800, halo: 16)
    let second = RestoreAIMath.featherWeight(pixel: pixel, origin: 360, size: 384, sourceOrigin: 360, sourceSize: 384, sourceImageSize: 800, halo: 16)
    return abs(first + second - 1) < 0.00001
}
expect(overlapWeightsSum, "AI feather weights span the full overlap and sum to one")
let cappedEdgeWeight = RestoreAIMath.featherWeight(pixel: 6263, origin: 5880, size: 384, sourceOrigin: 5880, sourceSize: 384, sourceImageSize: 8192, halo: 16)
expect(abs(cappedEdgeWeight - 1.0 / 16) < 0.00001, "AI feather edge detection uses source dimensions after output capping")
let sourceEdgeWeight = RestoreAIMath.featherWeight(pixel: 8191, origin: 7908, size: 384, sourceOrigin: 7908, sourceSize: 384, sourceImageSize: 8192, halo: 16)
expect(sourceEdgeWeight == 1, "AI source boundary keeps full tile weight")
expect(RestoreAIMath.tilePlan(width: 100, height: 100, tileSize: 16, overlap: 8, outputScale: 1).isEmpty, "invalid AI tile geometry is rejected")
expect(RestoreAIMath.tilePlan(width: 100, height: 100, tileSize: 384, overlap: 8, outputScale: 0).isEmpty, "invalid AI output scale is rejected")
try RestoreAIMath.validateSource(width: 8192, height: 4882)
expect(true, "AI source accepts the documented geometry boundary")
expectPreflightError({ try RestoreAIMath.validateSource(width: 8193, height: 100) }, "8192")
expectPreflightError({ try RestoreAIMath.validateOutput(width: 8000, height: 4001, isSuperResolution: true) }, "32MP")
try RestoreAIMath.validateOutput(width: 4096, height: 3072, isSuperResolution: false)
expect(true, "AI inpainting accepts a 12MP output")

let srSpec = RestoreModelCatalog.spec(for: .localSRFast)!
expect(srSpec.inputName == "image" && srSpec.outputName == "out", "LocalSR tensor names match the verified model")
expect(srSpec.inputShape == [1, 3, 384, 384] && srSpec.outputShape == [1, 3, 1536, 1536], "LocalSR tensor shapes match the verified model")
let localSRHashes = [
    "analytics/coremldata.bin": "9b6fc17c23f6b4e8330528fb4d014f0df1bded922b697ce911c293576861b738",
    "coremldata.bin": "350271dcda9bbd7e6f09da636e182536629707d230bb3a8b358fa1130c2ce589",
    "metadata.json": "33c6b596410829f25736947cac469f578277a6d39261180a67367e04ce60f915",
    "model.mil": "b5aaef64302fa4d12134880bd40f08e1408b45bf4b8a24d4088e76fda6f5f321",
    "weights/weight.bin": "00d5b0fd5d96cdfa5d87b466704dedbe4b51dcc291f4dd853308ac7b3378fb73"
]
expect(srSpec.totalByteCount == 350670, "LocalSR artifact sizes are pinned")
expect(srSpec.artifacts.allSatisfy { localSRHashes[String($0.relativePath.dropFirst(srSpec.bundleRelativePath.count + 1))] == $0.sha256 }, "LocalSR verifies every downloaded file with SHA-256")
expect(srSpec.artifacts.allSatisfy { $0.relativePath.hasPrefix(srSpec.bundleRelativePath + "/") }, "LocalSR bundle path contains every downloaded artifact")
expect(srSpec.artifacts.allSatisfy { $0.downloadURLs.count == 4 && $0.downloadURLs.allSatisfy { URL(string: $0)?.scheme == "https" } }, "LocalSR artifacts include HTTPS mirror and API fallbacks")
expect(srSpec.artifacts.allSatisfy { $0.downloadURLs.contains { $0.contains("fastly.jsdelivr.net") } && $0.downloadURLs.contains { $0.contains("api.github.com") } }, "LocalSR bypasses an unavailable raw GitHub route")
expect(srSpec.artifacts.allSatisfy { $0.downloadURLs.first?.contains("jsdelivr.net") == true }, "LocalSR tries working mirrors before the raw GitHub route")
let inpaintSpec = RestoreModelCatalog.spec(for: .aotGAN)!
expect(inpaintSpec.inputName == "x_1" && inpaintSpec.outputName == "var_915", "AOT-GAN tensor names match the verified model")
expect(inpaintSpec.dataType == .float32 && inpaintSpec.outputShape == nil, "AOT-GAN Float32 flexible output is validated at runtime")
expect(inpaintSpec.totalByteCount == 60818996 && inpaintSpec.artifacts[0].sha256 == "6090945f20e4971113457fa0bb90bca42e4569dcaf9ab7c183d2749ee4718b68", "AOT-GAN artifact size and SHA are pinned")
expect(inpaintSpec.artifacts[0].downloadURLs.contains("https://api.github.com/repos/john-rocky/AOT-GAN-for-Inpainting-CoreML/git/blobs/0e916772d239c30ce1dc72b5ec2af5df67d5e5a4"), "AOT-GAN has a pinned GitHub API raw-file fallback")

let emptyMask = RestoreMask()
expect(emptyMask.isEmpty, "empty repair mask is detected")
let erase = RestoreMaskStroke(points: [RestoreMaskPoint(x: 0.5, y: 0.5)], brushSize: 0.04, erasing: true)
let eraseOnlyMask = RestoreMask(strokes: [erase])
expect(eraseOnlyMask.isEmpty, "erase-only mask does not request repair")
var mask = RestoreMask()
mask.append(RestoreMaskStroke(points: [RestoreMaskPoint(x: -1, y: 2)], brushSize: 0.04))
mask.append(RestoreMaskStroke(points: [RestoreMaskPoint(x: 0.5, y: 0.5)], brushSize: -0.1))
expect(mask.strokes[0].points[0] == RestoreMaskPoint(x: 0, y: 1) && mask.strokes[0].brushSize == 0.04, "mask input is normalized and clamped")
expect(mask.strokes[1].brushSize == 0.002, "mask brush has a safe minimum")
let maskImage = try mask.rasterized(width: 64, height: 64)
let maskProvider = maskImage.dataProvider!
let maskData = maskProvider.data! as Data
let maskBytes = (maskData as NSData).bytes.assumingMemoryBound(to: UInt8.self)
let firstColumnHasPaint = (0..<64).contains { maskBytes[$0 * maskImage.bytesPerRow] > 0 }
expect(firstColumnHasPaint, "normalized mask coordinates rasterize at the expected edge")
let decodedMask = try JSONDecoder().decode(RestoreMask.self, from: JSONEncoder().encode(mask))
expect(decodedMask == mask, "repair mask survives codable round trip")

print("RESTORE-VERDICT PASS")
