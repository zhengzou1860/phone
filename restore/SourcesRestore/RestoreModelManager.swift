import Foundation
import CoreML
import CryptoKit

enum RestoreModelInstallState: Equatable {
    case notInstalled
    case downloading(Double)
    case compiling
    case installed
    case failed(String)
}

@MainActor
final class RestoreModelManager: ObservableObject {
    @Published private(set) var states: [RestoreModelID: RestoreModelInstallState] = [:]
    @Published private(set) var message: String?

    private let root: URL
    private var tasks: [RestoreModelID: Task<Void, Never>] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("HiRestore/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        removeIncompleteDownloads()
        refresh()
    }

    func state(for id: RestoreModelID) -> RestoreModelInstallState {
        states[id] ?? .notInstalled
    }

    func isInstalled(_ id: RestoreModelID) -> Bool {
        if case .installed = state(for: id) { return true }
        return false
    }

    func download(_ id: RestoreModelID) {
        guard !isInstalled(id), tasks[id] == nil, let spec = RestoreModelCatalog.spec(for: id) else { return }
        message = nil
        states[id] = .downloading(0)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.install(spec)
                try Task.checkCancellation()
                try await MainActor.run {
                    try Task.checkCancellation()
                    self.tasks[id] = nil
                    self.states[id] = .installed
                    self.message = "\(spec.name) 已下载并校验，可离线使用"
                    RestoreJournal.line("AI 模型就绪：\(spec.name) \(spec.version)")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.tasks[id] = nil
                    self.states[id] = (try? self.modelURL(for: id)) != nil ? .installed : .notInstalled
                    self.message = "已取消下载 \(spec.name)"
                }
            } catch {
                await MainActor.run {
                    self.tasks[id] = nil
                    if Task.isCancelled {
                        self.states[id] = (try? self.modelURL(for: id)) != nil ? .installed : .notInstalled
                        self.message = "已取消下载 \(spec.name)"
                    } else {
                        self.states[id] = .failed(error.localizedDescription)
                        self.message = "\(spec.name) 安装失败：\(error.localizedDescription)"
                        RestoreJournal.line("AI 模型安装失败：\(spec.name) \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func cancelDownload(_ id: RestoreModelID) {
        tasks[id]?.cancel()
        message = "正在取消下载 \(RestoreModelCatalog.spec(for: id)?.name ?? "AI 模型")"
    }

    func delete(_ id: RestoreModelID) {
        tasks[id]?.cancel()
        for component in ["Models", "Compiled", "Ready"] {
            let path = root.appendingPathComponent(component, isDirectory: true).appendingPathComponent(id.rawValue, isDirectory: true)
            try? FileManager.default.removeItem(at: path)
        }
        refresh()
        message = "已删除 \(RestoreModelCatalog.spec(for: id)?.name ?? "AI 模型")"
    }

    func modelURL(for id: RestoreModelID) throws -> URL {
        guard let spec = RestoreModelCatalog.spec(for: id) else { throw RestoreError.modelNotInstalled }
        let marker = readyMarker(id: id)
        guard let record = try? JSONDecoder().decode(ReadyRecord.self, from: Data(contentsOf: marker)),
              record.version == spec.version,
              record.catalogHash == spec.catalogHash else {
            throw RestoreError.modelNotInstalled
        }
        let url = root.appendingPathComponent("Compiled", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
            .appendingPathComponent(spec.version, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RestoreError.modelNotInstalled }
        return url
    }

    private func install(_ spec: RestoreModelSpec) async throws {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw RestoreError.fileOperation("无法读取模型下载可用空间")
        }
        let required = Int64(spec.totalByteCount) * 3 + 128 * 1024 * 1024
        try RestorePreflight.validateSpace(required: required, available: available)
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 1800
            return configuration
        }())
        defer { session.finishTasksAndInvalidate() }
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent("\(spec.id.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let total = spec.artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
        var completed: Int64 = 0
        for (index, artifact) in spec.artifacts.enumerated() {
            try Task.checkCancellation()
            states[spec.id] = .downloading(Double(completed) / Double(max(1, total)))
            guard let url = URL(string: artifact.downloadURL), url.scheme?.lowercased() == "https" else {
                throw RestoreError.modelLoadFailed("模型下载地址无效")
            }
            let (temporary, response) = try await session.download(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw RestoreError.modelLoadFailed("模型服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let destination = staging.appendingPathComponent(artifact.relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize == artifact.byteCount else {
                throw RestoreError.modelLoadFailed("\(artifact.relativePath) 大小校验失败")
            }
            if let expectedHash = artifact.sha256 {
                guard try sha256(of: destination) == expectedHash.lowercased() else {
                    throw RestoreError.modelLoadFailed("\(artifact.relativePath) 校验失败，请重试")
                }
            }
            completed += artifact.byteCount
            states[spec.id] = .downloading(Double(completed) / Double(max(1, total)))
            RestoreJournal.line("AI 模型下载：\(spec.name) \(index + 1)/\(spec.artifacts.count)")
        }

        try Task.checkCancellation()
        states[spec.id] = .compiling
        let source = staging.appendingPathComponent(spec.bundleRelativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RestoreError.modelLoadFailed("模型包不完整")
        }
        if let expectedTreeHash = spec.treeSHA256 {
            guard try sha256Tree(of: source) == expectedTreeHash.lowercased() else {
                throw RestoreError.modelLoadFailed("模型目录校验失败，请重试")
            }
        }
        let compiled = root.appendingPathComponent("Compiled", isDirectory: true)
            .appendingPathComponent(spec.id.rawValue, isDirectory: true)
            .appendingPathComponent(spec.version, isDirectory: true)
        try FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compiled)
        if source.pathExtension.lowercased() == "mlmodelc" {
            try FileManager.default.copyItem(at: source, to: compiled)
        } else {
            let result = try await MLModel.compileModel(at: source)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: result, to: compiled)
        }
        try Task.checkCancellation()

        let installed = root.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(spec.id.rawValue, isDirectory: true)
            .appendingPathComponent(spec.version, isDirectory: true)
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: staging, to: installed)
        _ = try RestoreInferenceCore.loadModel(compiled, spec: spec)
        let record = ReadyRecord(version: spec.version, catalogHash: spec.catalogHash)
        let marker = readyMarker(id: spec.id)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: marker, options: .atomic)
    }

    private func readyMarker(id: RestoreModelID) -> URL {
        root.appendingPathComponent("Ready", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
            .appendingPathComponent("\(RestoreModelCatalog.spec(for: id)?.version ?? "unknown").json")
    }

    private func refresh() {
        for id in RestoreModelID.allCases {
            if case .downloading = state(for: id) { continue }
            if case .compiling = state(for: id) { continue }
            states[id] = (try? modelURL(for: id)) != nil ? .installed : .notInstalled
        }
    }

    private func removeIncompleteDownloads() {
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
    }

    private func sha256Tree(of directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw RestoreError.modelLoadFailed("无法读取模型目录")
        }
        var files: [(path: String, hash: String)] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(directory.path.count + 1)).replacingOccurrences(of: "\\", with: "/")
            files.append((relative, try sha256(of: file)))
        }
        var hash = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(file.path.utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data(file.hash.utf8))
            hash.update(data: Data([0]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct ReadyRecord: Codable {
    let version: String
    let catalogHash: String
}
