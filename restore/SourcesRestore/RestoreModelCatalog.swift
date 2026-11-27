import Foundation

enum RestoreModelID: String, CaseIterable, Identifiable, Hashable, Codable {
    case realESRGAN
    case localSRFast
    case aotGAN

    var id: String { rawValue }
}

enum RestoreModelCompute: Equatable {
    case neuralEngine
    case gpu
}

enum RestoreModelDataType: String, Equatable {
    case float16
    case float32
}

struct RestoreModelArtifact: Equatable {
    let relativePath: String
    let downloadURL: String
    let byteCount: Int
    let sha256: String?
    let alternateDownloadURLs: [String]

    var downloadURLs: [String] { alternateDownloadURLs + [downloadURL] }

    init(relativePath: String, downloadURL: String, byteCount: Int, sha256: String?, alternateDownloadURLs: [String] = []) {
        self.relativePath = relativePath
        self.downloadURL = downloadURL
        self.byteCount = byteCount
        self.sha256 = sha256
        self.alternateDownloadURLs = alternateDownloadURLs
    }
}

struct RestoreModelSpec: Equatable, Identifiable {
    let id: RestoreModelID
    let name: String
    let version: String
    let summary: String
    let licenseLabel: String
    let attribution: String
    let sourceURL: String
    let bundleRelativePath: String
    let artifacts: [RestoreModelArtifact]
    let catalogHash: String
    let packagedByteCount: Int?
    let compute: RestoreModelCompute
    let inputName: String
    let outputName: String
    let inputShape: [Int]
    let outputShape: [Int]?
    let dataType: RestoreModelDataType
    let tileSize: Int
    let overlap: Int

    var totalByteCount: Int { packagedByteCount ?? artifacts.reduce(0) { $0 + $1.byteCount } }
    var isBundled: Bool { packagedByteCount != nil }
    var upscaleFactor: Int? {
        guard inputShape.count == 4, let outputShape, outputShape.count == 4,
              inputShape[3] > 0, outputShape[3] % inputShape[3] == 0 else { return nil }
        return outputShape[3] / inputShape[3]
    }
    var technicalSummary: String { "\(inputName) \(inputShape) → \(outputName) \(outputShape?.description ?? "运行时确定") · \(dataType.rawValue)" }
}

enum RestoreModelCatalog {
    private static let localSRCommit = "bba30194995e2815364f111168fb15155a24920f"
    private static let aotCommit = "8b3dcd14fc9ca89c08f7485b97ade6040640d835"

    static let all: [RestoreModelSpec] = [realESRGAN, localSRFast, aotGAN]

    static func spec(for id: RestoreModelID) -> RestoreModelSpec? {
        all.first { $0.id == id }
    }

    private static let realESRGAN = RestoreModelSpec(
        id: .realESRGAN,
        name: "RealESRGAN 高画质",
        version: "2.0.0",
        summary: "2× 真实感细节生成；384px 分块、32px 重叠融合，适合优先追求修复画质。",
        licenseLabel: "BSD-3-Clause",
        attribution: "Xintao Wang / Real-ESRGAN",
        sourceURL: "https://github.com/xintao/Real-ESRGAN",
        bundleRelativePath: "RealESRGAN_x2plus_384_fp16.mlmodelc",
        artifacts: [],
        catalogHash: "real-esrgan-x2plus-384-fp16-folded-v1",
        packagedByteCount: 33_580_688,
        compute: .gpu,
        inputName: "image",
        outputName: "out",
        inputShape: [1, 3, 384, 384],
        outputShape: [1, 3, 768, 768],
        dataType: .float32,
        tileSize: 384,
        overlap: 32
    )

    private static let localSRFast = RestoreModelSpec(
        id: .localSRFast,
        name: "LocalSR Fast",
        version: "1.0.0",
        summary: "4× 照片细节生成；固定 384px 小块推理，重叠融合后按输出上限缩放。",
        licenseLabel: "仓库 MIT；权重许可未单列",
        attribution: "HerRei / LocalSR · local-upscale",
        sourceURL: "https://github.com/HerRei/local-upscale",
        bundleRelativePath: "mobile/Models/ios/localsr_fast.mlmodelc",
        artifacts: [
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/analytics/coremldata.bin", 243, "9b6fc17c23f6b4e8330528fb4d014f0df1bded922b697ce911c293576861b738"),
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/coremldata.bin", 374, "350271dcda9bbd7e6f09da636e182536629707d230bb3a8b358fa1130c2ce589"),
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/metadata.json", 1790, "33c6b596410829f25736947cac469f578277a6d39261180a67367e04ce60f915"),
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/model.mil", 43207, "b5aaef64302fa4d12134880bd40f08e1408b45bf4b8a24d4088e76fda6f5f321"),
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/weights/weight.bin", 305056, "00d5b0fd5d96cdfa5d87b466704dedbe4b51dcc291f4dd853308ac7b3378fb73")
        ],
        catalogHash: "localsr-fast-bba3019-files-v2",
        packagedByteCount: nil,
        compute: .neuralEngine,
        inputName: "image",
        outputName: "out",
        inputShape: [1, 3, 384, 384],
        outputShape: [1, 3, 1536, 1536],
        dataType: .float16,
        tileSize: 384,
        overlap: 8
    )

    private static let aotGAN = RestoreModelSpec(
        id: .aotGAN,
        name: "AOT-GAN Places2",
        version: "1.0.0",
        summary: "512px 上下文缺损修补；只处理蒙版命中的小块，未选中画面保留原样。",
        licenseLabel: "上游 Apache-2.0；转换仓库许可未声明",
        attribution: "researchmm/AOT-GAN · john-rocky/Core ML conversion",
        sourceURL: "https://github.com/john-rocky/AOT-GAN-for-Inpainting-CoreML",
        bundleRelativePath: "aotgan.mlmodel",
        artifacts: [RestoreModelArtifact(
            relativePath: "aotgan.mlmodel",
            downloadURL: "https://raw.githubusercontent.com/john-rocky/AOT-GAN-for-Inpainting-CoreML/\(aotCommit)/AOT-GAN-for-Inpainting-CoreML/aotgan.mlmodel",
            byteCount: 60_818_996,
            sha256: "6090945f20e4971113457fa0bb90bca42e4569dcaf9ab7c183d2749ee4718b68",
            alternateDownloadURLs: [
                "https://api.github.com/repos/john-rocky/AOT-GAN-for-Inpainting-CoreML/git/blobs/0e916772d239c30ce1dc72b5ec2af5df67d5e5a4"
            ]
        )],
        catalogHash: "aot-gan-8b3dcd14-float32-v1",
        packagedByteCount: nil,
        compute: .gpu,
        inputName: "x_1",
        outputName: "var_915",
        inputShape: [1, 4, 512, 512],
        outputShape: nil,
        dataType: .float32,
        tileSize: 512,
        overlap: 32
    )

    private static func artifact(_ commit: String, _ path: String, _ byteCount: Int, _ sha256: String) -> RestoreModelArtifact {
        RestoreModelArtifact(
            relativePath: path,
            downloadURL: "https://raw.githubusercontent.com/HerRei/local-upscale/\(commit)/\(path)",
            byteCount: byteCount,
            sha256: sha256,
            alternateDownloadURLs: [
                "https://fastly.jsdelivr.net/gh/HerRei/local-upscale@\(commit)/\(path)",
                "https://gcore.jsdelivr.net/gh/HerRei/local-upscale@\(commit)/\(path)",
                "https://api.github.com/repos/HerRei/local-upscale/contents/\(path)?ref=\(commit)"
            ]
        )
    }
}
