import Foundation
import SwiftUI
import Photos
import AVFoundation
import UIKit

@MainActor
final class RestoreStore: ObservableObject {
    @Published private(set) var assets: [RestoredAsset] = []

    private let root: URL
    private let inputs: URL
    private let results: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("HiRestore", isDirectory: true)
        inputs = root.appendingPathComponent("Inputs", isDirectory: true)
        results = root.appendingPathComponent("Results", isDirectory: true)
        try? FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        reload()
    }

    func importMedia(from temporaryURL: URL, kind: MediaKind) async throws -> ImportedMedia {
        let id = UUID()
        let extensionName = temporaryURL.pathExtension.isEmpty ? (kind == .image ? "jpg" : "mov") : temporaryURL.pathExtension
        let destination = inputs.appendingPathComponent("source_\(id.uuidString).\(extensionName)")
        let cleanupTemporary = temporaryURL.path.hasPrefix(FileManager.default.temporaryDirectory.path + "/")
            && temporaryURL.lastPathComponent.hasPrefix("hirestore_pick_")
        defer {
            if cleanupTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let sourceSize = values.fileSize, sourceSize > 0, let available = values.volumeAvailableCapacityForImportantUsage else {
            throw RestoreError.fileOperation("无法读取原片大小或可用空间")
        }
        let width: Int
        let height: Int
        let duration: Double
        if kind == .image {
            let geometry = try ImageGeometry.load(temporaryURL)
            width = geometry.width
            height = geometry.height
            duration = 0
        } else {
            let geometry = try await VideoGeometry.load(temporaryURL)
            width = geometry.width
            height = geometry.height
            duration = geometry.duration
        }
        try RestorePreflight.validate(width: width, height: height, duration: duration, isVideo: kind == .video)
        let required = RestorePreflight.requiredImportBytes(sourceBytes: Int64(sourceSize))
        try RestorePreflight.validateSpace(required: required, available: available)
        RestoreJournal.line("导入预检通过：需要 \(RestoreMath.formatBytes(Int(required))) 可用空间，当前 \(RestoreMath.formatBytes(Int(available)))")
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        RestoreJournal.line("媒体已复制到沙盒：\(kind.rawValue) \(sourceSize) 字节")
        return ImportedMedia(
            id: id,
            url: destination,
            kind: kind,
            originalName: temporaryURL.lastPathComponent,
            byteCount: sourceSize,
            width: width,
            height: height,
            duration: duration
        )
    }

    func resultURL(filename: String) -> URL {
        results.appendingPathComponent(filename)
    }

    func resultURL(for asset: RestoredAsset) -> URL {
        resultURL(filename: asset.resultFilename)
    }

    func persistResult(from temporaryURL: URL, id: UUID, ext: String) throws -> String {
        let filename = RestoreMath.timestampName(prefix: "restore_\(id.uuidString.prefix(8))", ext: ext)
        let destination = results.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return filename
    }

    func sourceURL(for asset: RestoredAsset) -> URL {
        inputs.appendingPathComponent(asset.sourceFilename)
    }

    @discardableResult
    func register(_ asset: RestoredAsset) -> Bool {
        let metadataURL = results.appendingPathComponent("\(asset.id.uuidString).json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(asset).write(to: metadataURL, options: .atomic)
            reload()
            return true
        } catch {
            return false
        }
    }

    func delete(_ asset: RestoredAsset) {
        try? FileManager.default.removeItem(at: resultURL(for: asset))
        try? FileManager.default.removeItem(at: sourceURL(for: asset))
        try? FileManager.default.removeItem(at: results.appendingPathComponent("\(asset.id.uuidString).json"))
        reload()
        RestoreJournal.line("已删除修复记录：\(asset.kind.rawValue)")
    }

    func saveToPhotos(_ asset: RestoredAsset) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw RestoreError.photoPermissionDenied }
        let url = resultURL(for: asset)
        let data: Data?
        if asset.kind == .image {
            guard let imageData = try? Data(contentsOf: url) else {
                throw RestoreError.fileOperation("无法读取修复后的照片")
            }
            data = imageData
        } else {
            data = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                if let data {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                } else {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? RestoreError.fileOperation("系统相册保存失败"))
                }
            }
        }
        RestoreJournal.line("已保存到系统相册：\(asset.kind.rawValue)")
    }

    func thumbnail(for asset: RestoredAsset, maxPixel: Int = 720) async -> UIImage? {
        let url = resultURL(for: asset)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if asset.kind == .image {
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            return await Task.detached(priority: .utility) {
                image.preparingThumbnail(of: CGSize(width: maxPixel, height: maxPixel))
            }.value
        }
        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let semaphore = DispatchSemaphore(value: 0)
            var result: UIImage?
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cgImage, _, _, _ in
                if let cgImage = cgImage { result = UIImage(cgImage: cgImage) }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 15) == .timedOut { generator.cancelAllCGImageGeneration() }
            return result
        }.value
    }

    private func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: results, includingPropertiesForKeys: nil)) ?? []
        assets = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(RestoredAsset.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: resultURL(for: $0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
