import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("RESTORE-ARCHIVE FAIL \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = URL(fileURLWithPath: CommandLine.arguments[2])
let unsafe = URL(fileURLWithPath: CommandLine.arguments[3])
let truncated = URL(fileURLWithPath: CommandLine.arguments[4])
let deflated = URL(fileURLWithPath: CommandLine.arguments[5])
let output = root.appendingPathComponent("extracted", isDirectory: true)

try RestoreModelArchive.extractStoredZip(at: source, to: output)
let model = output.appendingPathComponent("gfpgan.mlmodelc/model.mil")
let weights = output.appendingPathComponent("gfpgan.mlmodelc/weights/weight.bin")
guard try Data(contentsOf: model) == Data("model".utf8),
      try Data(contentsOf: weights) == Data([0, 1, 2, 3, 255]) else {
    fail("content")
}
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: output.appendingPathComponent("empty").path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail("directory")
}
for invalid in [unsafe, truncated, deflated] {
    do {
        try RestoreModelArchive.extractStoredZip(at: invalid, to: root.appendingPathComponent(invalid.lastPathComponent))
        fail("accepted \(invalid.lastPathComponent)")
    } catch {
        print("RESTORE-ARCHIVE REJECTED \(invalid.lastPathComponent): \(error.localizedDescription)")
    }
}
print("RESTORE-ARCHIVE-VERDICT PASS")
