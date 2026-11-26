import Foundation

enum RestoreModelID: String, CaseIterable, Identifiable, Hashable {
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
}

struct RestoreModelSpec: Equatable {
    let id: RestoreModelID
    let name: String
    let version: String
    let summary: String
    let licenseLabel: String
    let attribution: String
    let sourceURL: String
    let bundleRelativePath: String
    let artifacts: [RestoreModelArtifact]
    let treeSHA256: String?
    let catalogHash: String
    let compute: RestoreModelCompute
    let inputName: String
    let outputName: String
    let inputShape: [Int]
    let outputShape: [Int]?
    let dataType: RestoreModelDataType
    let tileSize: Int
    let overlap: Int

    var totalByteCount: Int { artifacts.reduce(0) { $0 + $1.byteCount } }
    var technicalSummary: String { "\(inputName) \(inputShape) → \(outputName) \(outputShape?.description ?? "运行时确定") · \(dataType.rawValue)" }
}

enum RestoreModelCatalog {
    private static let localSRCommit = "bba30194995e2815364f111168fb15155a24920f"
    private static let aotCommit = "8b3dcd14fc9ca89c08f7485b97ade6040640d835"

    static let all: [RestoreModelSpec] = [localSRFast, aotGAN]

    static func spec(for id: RestoreModelID) -> RestoreModelSpec? {
        all.first { $0.id == id }
    }

    private static let localSRFast = RestoreModelSpec(
        id: .localSRFast,
        name: "LocalSR Fast",
        version: "1.0.0",
        summary: "4× 照片细节生成；固定 384px 小块推理，重叠融合后按输出上限缩放。",
        licenseLabel: "仓库 MIT；权重许可未单列",
        attribution: "HerRei / LocalSR · local-upscale",
        sourceURL: "https://github.com/HerRei/local-upscale",
        bundleRelativePath: "localsr_fast.mlmodelc",
        artifacts: [
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/analytics/coremldata.bin", 243),
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/coremldata.bin", 374),
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/metadata.json", 1790),
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/model.mil", 43207),
            artifact(localSRCommit, "mobile/Models/ios/localsr_fast.mlmodelc/weights/weight.bin", 305056)
        ],
        treeSHA256: "26358751077f4e3b9fa428bd5a21354774ad53ec80212fee46b17bcd1877eabc",
        catalogHash: "localsr-fast-bba3019-tree-v1",
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
            sha256: "6090945f20e4971113457fa0bb90bca42e4569dcaf9ab7c183d2749ee4718b68"
        )],
        treeSHA256: nil,
        catalogHash: "aot-gan-8b3dcd14-float32-v1",
        compute: .gpu,
        inputName: "x_1",
        outputName: "var_915",
        inputShape: [1, 4, 512, 512],
        outputShape: nil,
        dataType: .float32,
        tileSize: 512,
        overlap: 32
    )

    private static func artifact(_ commit: String, _ path: String, _ byteCount: Int) -> RestoreModelArtifact {
        RestoreModelArtifact(
            relativePath: path,
            downloadURL: "https://raw.githubusercontent.com/HerRei/local-upscale/\(commit)/\(path)",
            byteCount: byteCount,
            sha256: nil
        )
    }
}
