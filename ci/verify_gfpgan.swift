import CoreML
import CoreGraphics
import CoreVideo
import Foundation

func verifyGFPGAN(at path: String) throws {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndGPU
    let model = try MLModel(contentsOf: URL(fileURLWithPath: path), configuration: configuration)
    guard let input = model.modelDescription.inputDescriptionsByName["x_1"]?.imageConstraint,
          let output = model.modelDescription.outputDescriptionsByName["activation_out"]?.imageConstraint,
          input.pixelsWide == 512, input.pixelsHigh == 512,
          output.pixelsWide == 512, output.pixelsHigh == 512 else {
        throw NSError(domain: "GFPGANVerify", code: 1, userInfo: [NSLocalizedDescriptionKey: "compiled interface mismatch"])
    }
    guard let context = CGContext(
        data: nil,
        width: 512,
        height: 512,
        bitsPerComponent: 8,
        bytesPerRow: 512 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "GFPGANVerify", code: 2, userInfo: [NSLocalizedDescriptionKey: "test image allocation failed"])
    }
    context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    guard let image = context.makeImage() else {
        throw NSError(domain: "GFPGANVerify", code: 3, userInfo: [NSLocalizedDescriptionKey: "test image creation failed"])
    }
    let provider = try MLDictionaryFeatureProvider(dictionary: ["x_1": try MLFeatureValue(cgImage: image, constraint: input)])
    let result = try model.prediction(from: provider)
    guard let pixelBuffer = result.featureValue(for: "activation_out")?.imageBufferValue,
          CVPixelBufferGetWidth(pixelBuffer) == 512,
          CVPixelBufferGetHeight(pixelBuffer) == 512 else {
        throw NSError(domain: "GFPGANVerify", code: 4, userInfo: [NSLocalizedDescriptionKey: "compiled prediction failed"])
    }
}

#if os(iOS)
guard let modelURL = Bundle.main.url(forResource: "gfpgan", withExtension: "mlmodelc") else {
    FileHandle.standardError.write(Data("GFPGAN-IOS18-VERDICT FAIL compiled model missing\n".utf8))
    exit(1)
}
let path = modelURL.path
#else
let path = CommandLine.arguments.dropFirst().first ?? "/tmp/gfpgan.mlmodelc"
#endif

do {
    try verifyGFPGAN(at: path)
    #if os(iOS)
    print("GFPGAN-IOS18-VERDICT PASS input=512x512 output=512x512")
    #else
    print("GFPGAN-COMPILED-VERDICT PASS input=512x512 output=512x512")
    #endif
} catch {
    #if os(iOS)
    FileHandle.standardError.write(Data("GFPGAN-IOS18-VERDICT FAIL \(error.localizedDescription)\n".utf8))
    #else
    FileHandle.standardError.write(Data("GFPGAN-COMPILED-VERDICT FAIL \(error.localizedDescription)\n".utf8))
    #endif
    exit(1)
}
