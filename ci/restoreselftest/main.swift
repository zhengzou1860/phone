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

let small = RestoreMath.fittedSize(width: 640, height: 480, scale: 1.5, maxLongEdge: 3840)
expect(small.width == 960 && small.height == 720, "1.5x upscale keeps exact aspect ratio")

print("RESTORE-VERDICT PASS")
