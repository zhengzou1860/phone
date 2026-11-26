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

let manyLines = (0..<1005).map { "line \($0)" }
expect(RestoreJournal.compact(manyLines).count == 1000, "runtime journal keeps only the latest 1000 lines")
let largeLines = (0..<1000).map { _ in String(repeating: "x", count: 1000) }
let compacted = RestoreJournal.compact(largeLines)
expect(compacted.joined(separator: "\n").utf8.count <= 512 * 1024, "runtime journal respects its byte cap")

print("RESTORE-VERDICT PASS")
