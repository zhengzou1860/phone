import CoreML
import CoreGraphics
import CoreVideo
import Foundation

let path = CommandLine.arguments.dropFirst().first ?? "/tmp/gfpgan.mlmodelc"
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuAndGPU
let model = try MLModel(contentsOf: URL(fileURLWithPath: path), configuration: configuration)
guard let input = model.modelDescription.inputDescriptionsByName["x_1"]?.imageConstraint,
      let output = model.modelDescription.outputDescriptionsByName["activation_out"]?.imageConstraint,
      input.pixelsWide == 512, input.pixelsHigh == 512,
      output.pixelsWide == 512, output.pixelsHigh == 512 else {
    fatalError("GFPGAN compiled interface mismatch")
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
    fatalError("GFPGAN test image allocation failed")
}
context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
guard let image = context.makeImage() else {
    fatalError("GFPGAN test image creation failed")
}
let provider = try MLDictionaryFeatureProvider(dictionary: ["x_1": try MLFeatureValue(cgImage: image, constraint: input)])
let result = try model.prediction(from: provider)
guard let pixelBuffer = result.featureValue(for: "activation_out")?.imageBufferValue,
      CVPixelBufferGetWidth(pixelBuffer) == 512,
      CVPixelBufferGetHeight(pixelBuffer) == 512 else {
    fatalError("GFPGAN compiled prediction failed")
}
print("GFPGAN-COMPILED-VERDICT PASS input=512x512 output=512x512")
