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

let waitingDownload = RestoreDownloadProgress.waiting
expect(waitingDownload.fraction == 0 && waitingDownload.summary.contains("正在连接"), "waiting model download is distinct from zero-byte transfer")
let stalledDownload = RestoreDownloadProgress(
    phase: .downloading,
    receivedBytes: 3 * megabyte,
    totalBytes: 100 * megabyte,
    bytesPerSecond: 35 * 1024,
    elapsedSeconds: 90,
    idleSeconds: 12,
    remainingSeconds: nil,
    sourceHost: "gh-proxy.com"
)
expect(stalledDownload.summary.contains("gh-proxy.com") && stalledDownload.summary.contains("12 秒无数据"), "stalled model download reports source and idle time")
expect(!stalledDownload.summary.contains("约剩"), "stalled model download does not show a stale completion estimate")
let movingDownload = RestoreDownloadProgress(
    phase: .downloading,
    receivedBytes: 50 * megabyte,
    totalBytes: 100 * megabyte,
    bytesPerSecond: Double(megabyte) / 2,
    elapsedSeconds: 100,
    idleSeconds: 0,
    remainingSeconds: 100,
    sourceHost: "ghfast.top"
)
expect(movingDownload.fraction == 0.5 && movingDownload.summary.contains("约剩 1分40秒"), "moving model download reports progress and remaining time")
let verifyingDownload = RestoreDownloadProgress(
    phase: .verifying,
    receivedBytes: 100 * megabyte,
    totalBytes: 100 * megabyte,
    bytesPerSecond: Double(megabyte),
    elapsedSeconds: 100,
    idleSeconds: 0,
    remainingSeconds: nil,
    sourceHost: "github.com"
)
expect(verifyingDownload.fraction == 1 && verifyingDownload.summary.contains("正在校验"), "completed model transfer enters verification without claiming installation")
expect(RestoreMath.formatSpeed(1024) == "1.0 KB/s" && RestoreMath.downloadDuration(90) == "1分30秒", "download diagnostics format speed and duration consistently")

let manyLines = (0..<1005).map { "line \($0)" }
expect(RestoreJournal.compact(manyLines).count == 1000, "runtime journal keeps only the latest 1000 lines")
let largeLines = (0..<1000).map { _ in String(repeating: "x", count: 1000) }
let compacted = RestoreJournal.compact(largeLines)
expect(compacted.joined(separator: "\n").utf8.count <= 512 * 1024, "runtime journal respects its byte cap")
let exportedLog = try RestoreJournal.exportSnapshot(details: "selftest device")
expect(exportedLog.lastPathComponent.hasPrefix("HiRestore-runtime-") && exportedLog.pathExtension == "log", "runtime journal exports a recognizable local log file")
expect(try String(contentsOf: exportedLog, encoding: .utf8).contains("selftest device"), "exported log includes device diagnostics")
try? FileManager.default.removeItem(at: exportedLog)

let singleAITile = RestoreAIMath.tilePlan(width: 300, height: 200, tileSize: 384, overlap: 8, outputScale: 1)
expect(singleAITile.count == 1 && singleAITile[0].originX == 0 && singleAITile[0].originY == 0, "small AI image uses one padded tile")
let edgeAITiles = RestoreAIMath.tilePlan(width: 384, height: 384, tileSize: 384, overlap: 8, outputScale: 1)
expect(edgeAITiles.count == 1 && edgeAITiles[0].originX == 0, "exact-size AI image does not create empty edge tiles")
let phoneAITiles = RestoreAIMath.tilePlan(width: 585, height: 790, tileSize: 384, overlap: 8, outputScale: 2)
expect(phoneAITiles.count == 6, "585x790 AI image uses a complete 2x3 tile grid")
expect(Set(phoneAITiles.map { $0.originX }) == Set([0, 201]), "AI columns do not add a redundant overlapping tile")
expect(Set(phoneAITiles.map { $0.originY }) == Set([0, 368, 406]), "AI rows cover the full photo height")
expect(phoneAITiles.contains { $0.originX == 0 && $0.originY == 0 }, "AI tile grid starts at the top-left photo boundary")
expect(phoneAITiles.contains { $0.originX == 201 && $0.originY == 406 }, "AI edge tiles stay anchored to the right and bottom photo boundaries")
expect(phoneAITiles.allSatisfy { $0.originX >= 0 && $0.originX + 384 <= 585 && $0.originY >= 0 && $0.originY + 384 <= 790 }, "AI tiles never extend beyond the source photo")
let firstPhoneTile = phoneAITiles.first { $0.originX == 0 && $0.originY == 0 }!
let rightPhoneTile = phoneAITiles.first { $0.originX == 201 && $0.originY == 0 }!
let lowerPhoneTile = phoneAITiles.first { $0.originX == 0 && $0.originY == 368 }!
let bottomPhoneTile = phoneAITiles.first { $0.originX == 0 && $0.originY == 406 }!
expect(firstPhoneTile.overlapRight == 183 && rightPhoneTile.overlapLeft == 183, "edge anchoring records the actual 183px horizontal overlap")
expect(lowerPhoneTile.overlapBottom == 346 && bottomPhoneTile.overlapTop == 346, "edge anchoring records the actual 346px vertical overlap")
let largeOverlapWeightsSum = (201..<384).allSatisfy { pixel in
    let first = RestoreAIMath.featherWeight(pixel: pixel, origin: 0, size: 384, sourceOrigin: 0, sourceSize: 384, sourceImageSize: 585, halo: Double(firstPhoneTile.overlapRight))
    let second = RestoreAIMath.featherWeight(pixel: pixel, origin: 201, size: 384, sourceOrigin: 201, sourceSize: 384, sourceImageSize: 585, halo: Double(rightPhoneTile.overlapLeft))
    return abs(first + second - 1) < 0.00001
}
expect(largeOverlapWeightsSum, "actual large-overlap feather weights remain complementary without darkening")
expect(RestoreAIMath.featherWeight(pixel: 184, origin: 0, size: 384, sourceOrigin: 0, sourceSize: 384, sourceImageSize: 585, halo: Double(firstPhoneTile.overlapRight)) == 1, "large-overlap feathering does not dim pixels before the overlap begins")
let wideAITiles = RestoreAIMath.tilePlan(width: 800, height: 100, tileSize: 384, overlap: 8, outputScale: 1)
expect(wideAITiles.map { $0.originX } == [0, 368, 416], "wide AI images anchor the final column after regular overlap")
expect(RestoreAIMath.featherWeight(pixel: 0, origin: 0, size: 384, sourceOrigin: 0, sourceSize: 384, sourceImageSize: 585, halo: 8) == 1, "AI source left edge keeps full tile weight")
expect(RestoreAIMath.featherWeight(pixel: 383, origin: 201, size: 384, sourceOrigin: 201, sourceSize: 384, sourceImageSize: 585, halo: 8) == 1, "AI source right edge keeps full tile weight")
let overlapWeightsSum = (368..<384).allSatisfy { pixel in
    let first = RestoreAIMath.featherWeight(pixel: pixel, origin: 0, size: 384, sourceOrigin: 0, sourceSize: 384, sourceImageSize: 800, halo: 16)
    let second = RestoreAIMath.featherWeight(pixel: pixel, origin: 368, size: 384, sourceOrigin: 368, sourceSize: 384, sourceImageSize: 800, halo: 16)
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
expectPreflightError({ try RestoreAIMath.validateOutput(width: 8000, height: 4001) }, "32MP")
try RestoreAIMath.validateOutput(width: 8000, height: 4000)
expect(true, "AI super-resolution accepts a 32MP output")

let srSpec = RestoreModelCatalog.spec(for: .localSRFast)!
let realSpec = RestoreModelCatalog.spec(for: .realESRGAN)!
expect(realSpec.isBundled && realSpec.totalByteCount == 33580688 && realSpec.artifacts.isEmpty, "RealESRGAN is packaged offline at its verified size")
expect(realSpec.inputName == "image" && realSpec.outputName == "out", "RealESRGAN tensor names match the verified model")
expect(realSpec.inputShape == [1, 3, 384, 384] && realSpec.outputShape == [1, 3, 768, 768], "RealESRGAN tensor shapes match the verified model")
expect(realSpec.dataType == .float32 && realSpec.compute == .gpu && realSpec.overlap == 32, "RealESRGAN uses its verified FP32 tensor interface with GPU tiling")
expect(realSpec.upscaleFactor == 2 && srSpec.upscaleFactor == 4, "super-resolution summaries distinguish 2x and 4x models")
expect(RestoreModelCatalog.all.count == 3, "model catalog includes RealESRGAN, LocalSR Fast, and GFPGAN")
let faceSpec = RestoreModelCatalog.spec(for: .gfpgan)!
expect(faceSpec.interface == .image && faceSpec.inputName == "x_1" && faceSpec.outputName == "activation_out", "GFPGAN uses its verified image feature names")
expect(faceSpec.tileSize == 512 && faceSpec.totalByteCount == 337900799, "GFPGAN uses a verified 512px interface and pinned precompiled package size")
expect(faceSpec.bundleRelativePath == "gfpgan.mlmodelc" && faceSpec.artifacts[0].isArchive, "GFPGAN installs an extracted precompiled model bundle")
expect(RestoreModelCatalog.all.allSatisfy({ RestoreModelStorage.compiledURL(root: URL(fileURLWithPath: "/models"), spec: $0).pathExtension.lowercased() == "mlmodelc" }), "every installed model path preserves the Core ML bundle extension")
let modelStorageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("HiRestore-model-storage-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: modelStorageRoot) }
let legacyFaceURL = RestoreModelStorage.legacyCompiledURL(root: modelStorageRoot, spec: faceSpec)
try FileManager.default.createDirectory(at: legacyFaceURL, withIntermediateDirectories: true)
try Data("compiled-model".utf8).write(to: legacyFaceURL.appendingPathComponent("model.espresso.net"))
let migratedFaceURL = try RestoreModelStorage.resolveCompiledModel(root: modelStorageRoot, spec: faceSpec)
expect(migratedFaceURL == RestoreModelStorage.compiledURL(root: modelStorageRoot, spec: faceSpec) && migratedFaceURL.pathExtension == "mlmodelc", "legacy GFPGAN migrates to a versioned mlmodelc bundle")
let migratedContents = try Data(contentsOf: migratedFaceURL.appendingPathComponent("model.espresso.net"))
expect(!FileManager.default.fileExists(atPath: legacyFaceURL.path) && migratedContents == Data("compiled-model".utf8), "legacy model migration preserves compiled files without copying or downloading")
expect(try RestoreModelStorage.resolveCompiledModel(root: modelStorageRoot, spec: faceSpec) == migratedFaceURL, "model path resolution is stable after migration")
expect(faceSpec.artifacts[0].sha256 == "c657ae0d9c2d10e03ee6f11f2c521a9b65011f5e1fb2c5b83ee964905ca25ec3", "GFPGAN verifies the downloaded archive with SHA-256")
expect(faceSpec.artifacts[0].downloadURLs.allSatisfy { URL(string: $0)?.scheme == "https" }, "GFPGAN downloads only over HTTPS")
let faceSources = faceSpec.artifacts[0].downloadURLs
expect(faceSources.count == 3 && faceSources[0].contains("gh-proxy.com/") && faceSources[1].contains("ghfast.top/") && faceSources[2].contains("github.com/"), "GFPGAN prefers accelerated mirrors and keeps the official fallback")
expect(faceSources.allSatisfy { $0.hasSuffix("/gfpgan-ios18.zip") }, "GFPGAN mirrors serve the same pinned precompiled archive")
let landmarkCenter = RestoreFaceMath.imagePoint(CGPoint(x: 0.5, y: 0.5), faceBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), imageSize: CGSize(width: 1000, height: 800))
expect(abs(landmarkCenter.x - 500) < 0.0001 && abs(landmarkCenter.y - 400) < 0.0001, "Vision landmarks map from the face box into upper-left image coordinates")
let identityFace = RestoreFaceMath.similarityTransform(from: RestoreFaceMath.template)!
expect(abs(identityFace.matrix.a - 1) < 0.000001 && abs(identityFace.matrix.d - 1) < 0.000001 && abs(identityFace.matrix.tx) < 0.000001 && abs(identityFace.matrix.ty) < 0.000001, "face alignment identity transform preserves the 512px template")
let scaledFaceSource = RestoreFaceMath.template.map { CGPoint(x: $0.x * 0.4 + 300, y: $0.y * 0.4 - 80) }
let scaledFace = RestoreFaceMath.similarityTransform(from: scaledFaceSource)!
expect((0..<5).allSatisfy { index in
    let point = scaledFace.apply(scaledFaceSource[index])
    let expected = RestoreFaceMath.template[index]
    return abs(point.x - expected.x) < 0.0001 && abs(point.y - expected.y) < 0.0001
}, "face alignment recovers scale and translation without drift")
let angle = 0.3
let rotatedFaceSource = RestoreFaceMath.template.map { point in
    CGPoint(x: cos(angle) * point.x - sin(angle) * point.y, y: sin(angle) * point.x + cos(angle) * point.y)
}
let rotatedFace = RestoreFaceMath.similarityTransform(from: rotatedFaceSource)!
expect((0..<5).allSatisfy { index in
    let point = rotatedFace.apply(rotatedFaceSource[index])
    let expected = RestoreFaceMath.template[index]
    return abs(point.x - expected.x) < 0.0001 && abs(point.y - expected.y) < 0.0001
}, "face alignment removes in-plane face rotation")
expect(RestoreFaceMath.similarityTransform(from: Array(repeating: CGPoint(x: 10, y: 10), count: 5)) == nil, "face alignment rejects degenerate landmarks")
let contextFaceSource = CGPoint(x: 140, y: 90)
let contextAligned = rotatedFace.apply(contextFaceSource)
let contextInput = CGPoint(x: contextFaceSource.x, y: 512 - contextFaceSource.y)
let contextPoint = contextInput.applying(RestoreFaceMath.coreGraphicsTransform(rotatedFace, size: 512))
expect(abs(contextPoint.x - contextAligned.x) < 0.0001 && abs(contextPoint.y - (512 - contextAligned.y)) < 0.0001, "face alignment converts upper-left landmarks into Core Graphics coordinates")
let inverseFace = RestoreFaceTransform(matrix: rotatedFace.matrix.inverted(), scale: 1 / rotatedFace.scale)
let patchPoint = CGPoint(x: contextAligned.x, y: 512 - contextAligned.y)
let pastedPoint = patchPoint.applying(RestoreFaceMath.coreGraphicsTransform(inverseFace, size: 512))
expect(abs(pastedPoint.x - contextFaceSource.x) < 0.0001 && abs(pastedPoint.y - (512 - contextFaceSource.y)) < 0.0001, "face patch inverse transform returns to the source location")
expect(RestoreFaceMath.featherAlpha(pixelX: 256, pixelY: 281, size: 512) == 1, "face feather keeps the central facial area fully opaque")
expect(RestoreFaceMath.featherAlpha(pixelX: 0, pixelY: 0, size: 512) == 0, "face feather leaves the aligned crop border transparent")
expect(RestoreFaceMath.featherAlpha(pixelX: 256, pixelY: 70, size: 512) < RestoreFaceMath.featherAlpha(pixelX: 256, pixelY: 200, size: 512), "face feather fades continuously toward the forehead")
let faceMask = try RestoreFaceMath.featherMask(size: 64)
expect(faceMask.width == 64 && faceMask.height == 64, "face feather mask matches the inference patch dimensions")
let encodedModelID = try JSONEncoder().encode(RestoreModelID.realESRGAN)
let decodedModelID = try JSONDecoder().decode(RestoreModelID.self, from: encodedModelID)
expect(decodedModelID == .realESRGAN, "selected super-resolution model survives Codable settings round trips")

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
print("RESTORE-VERDICT PASS")
