import Foundation
import CoreML
import CryptoKit

enum RestoreModelInstallState: Equatable {
    case notInstalled
    case downloading(RestoreDownloadProgress)
    case compiling
    case installed
    case failed(String)
}

@MainActor
final class RestoreModelManager: ObservableObject {
    @Published private(set) var states: [RestoreModelID: RestoreModelInstallState] = [:]
    @Published private(set) var message: String?

    private struct DownloadMetrics {
        var attemptID: UUID
        var phase: RestoreDownloadPhase
        var sourceHost: String
        var baselineBytes: Int64
        var artifactBytes: Int64
        var receivedBytes: Int64
        var startedAt: Date
        var lastBytesAt: Date
        var lastLoggedAt: Date
    }

    private let root: URL
    private var tasks: [RestoreModelID: Task<Void, Never>] = [:]
    private var progressTimers: [RestoreModelID: Task<Void, Never>] = [:]
    private var downloadMetrics: [RestoreModelID: DownloadMetrics] = [:]
    private var activeModelUses: [RestoreModelID: Int] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("HiRestore/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        removeIncompleteDownloads()
        refresh()
    }

    func state(for id: RestoreModelID) -> RestoreModelInstallState {
        if let spec = RestoreModelCatalog.spec(for: id), spec.isBundled {
            return bundledModelURL(spec) != nil ? .installed : .failed("安装包中缺少模型资源")
        }
        return states[id] ?? .notInstalled
    }

    func isInstalled(_ id: RestoreModelID) -> Bool {
        if case .installed = state(for: id) { return true }
        return false
    }

    func download(_ id: RestoreModelID) {
        guard !isInstalled(id), tasks[id] == nil, let spec = RestoreModelCatalog.spec(for: id), !spec.isBundled else { return }
        message = nil
        states[id] = .downloading(.waiting)
        startProgressTimer(for: id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.install(spec)
                try Task.checkCancellation()
                self.stopDownloadTracking(for: id)
                self.tasks[id] = nil
                self.states[id] = .installed
                self.message = "\(spec.name) 已下载并校验，可离线使用"
                RestoreJournal.line("AI 模型就绪：\(spec.name) \(spec.version)")
            } catch is CancellationError {
                self.stopDownloadTracking(for: id)
                self.tasks[id] = nil
                self.states[id] = (try? self.modelURL(for: id)) != nil ? .installed : .notInstalled
                self.message = "已取消下载 \(spec.name)"
            } catch {
                self.stopDownloadTracking(for: id)
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

    func cancelDownload(_ id: RestoreModelID) {
        tasks[id]?.cancel()
        message = "正在取消下载 \(RestoreModelCatalog.spec(for: id)?.name ?? "AI 模型")"
    }

    func delete(_ id: RestoreModelID) async {
        if let task = tasks[id] {
            task.cancel()
            await task.value
        }
        let name = RestoreModelCatalog.spec(for: id)?.name ?? "AI 模型"
        if RestoreModelCatalog.spec(for: id)?.isBundled == true {
            message = "\(name) 已内置在安装包中，无需下载，也不能删除"
            return
        }
        guard activeModelUses[id, default: 0] == 0 else {
            message = "\(name) 正在用于照片修复，请完成或停止后再删除"
            return
        }
        guard tasks[id] == nil else {
            message = "\(name) 正在准备，请稍后再删除"
            return
        }
        for component in ["Models", "Compiled", "Ready"] {
            let path = root.appendingPathComponent(component, isDirectory: true).appendingPathComponent(id.rawValue, isDirectory: true)
            try? FileManager.default.removeItem(at: path)
        }
        refresh()
        message = "已删除 \(name)"
    }

    func beginProcessing(_ id: RestoreModelID) throws -> URL {
        let url = try modelURL(for: id)
        activeModelUses[id, default: 0] += 1
        return url
    }

    func endProcessing(_ id: RestoreModelID) {
        let count = activeModelUses[id, default: 0]
        if count <= 1 {
            activeModelUses[id] = nil
        } else {
            activeModelUses[id] = count - 1
        }
    }

    func modelURL(for id: RestoreModelID) throws -> URL {
        guard let spec = RestoreModelCatalog.spec(for: id) else { throw RestoreError.modelNotInstalled }
        if spec.isBundled {
            guard let url = bundledModelURL(spec) else { throw RestoreError.modelNotInstalled }
            return url
        }
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

    private func downloadArtifact(
        _ artifact: RestoreModelArtifact,
        from source: String,
        spec: RestoreModelSpec,
        attemptID: UUID,
        configuration: URLSessionConfiguration,
        staging: URL
    ) async throws {
        guard let url = URL(string: source), url.scheme?.lowercased() == "https" else {
            throw RestoreError.modelLoadFailed("模型下载地址无效")
        }
        let host = url.host ?? source
        let delegate = RestoreModelDownloadDelegate(expectedBytes: Int64(artifact.byteCount)) { [weak self] written, expected in
            guard let self else { return }
            Task { @MainActor in
                self.recordDownloadProgress(for: spec.id, attemptID: attemptID, host: host, written: written, expected: expected)
            }
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (temporary, response) = try await delegate.download(request, configuration: configuration)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RestoreError.modelLoadFailed("模型服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        markDownloadVerifying(for: spec.id)
        RestoreJournal.line("AI 模型文件下载完成：\(spec.name) \(host)，正在校验大小和 SHA-256")
        let destination = staging.appendingPathComponent(artifact.relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == artifact.byteCount else {
            throw RestoreError.modelLoadFailed("\(artifact.relativePath) 大小校验失败")
        }
        if let expectedHash = artifact.sha256 {
            let actualHash = try await Self.sha256(of: destination)
            guard actualHash == expectedHash.lowercased() else {
                throw RestoreError.modelLoadFailed("\(artifact.relativePath) 校验失败（实际 \(actualHash.prefix(12))）")
            }
        }
    }

    private func install(_ spec: RestoreModelSpec) async throws {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw RestoreError.fileOperation("无法读取模型下载可用空间")
        }
        let required = Int64(spec.totalByteCount) * 3 + 128 * 1024 * 1024
        try RestorePreflight.validateSpace(required: required, available: available)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent("\(spec.id.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var completed: Int64 = 0
        for (index, artifact) in spec.artifacts.enumerated() {
            try Task.checkCancellation()
            var downloadError: Error?
            var downloaded = false
            for source in artifact.downloadURLs {
                try Task.checkCancellation()
                let host = URL(string: source)?.host ?? source
                let attemptID = beginDownloadSource(for: spec.id, host: host, baselineBytes: completed, artifactBytes: Int64(artifact.byteCount))
                RestoreJournal.line("AI 模型开始下载：\(spec.name) \(index + 1)/\(spec.artifacts.count) · \(host) · \(RestoreMath.formatBytes(spec.totalByteCount))")
                do {
                    try await downloadArtifact(
                        artifact,
                        from: source,
                        spec: spec,
                        attemptID: attemptID,
                        configuration: configuration,
                        staging: staging
                    )
                    if let progress = currentDownloadProgress(for: spec.id) {
                        RestoreJournal.line("AI 模型下载源成功：\(host) · \(progress.summary)")
                    }
                    downloaded = true
                    break
                } catch {
                    if Task.isCancelled { throw error }
                    downloadError = error
                    logDownloadInterruption(for: spec.id, error: error)
                }
            }
            guard downloaded else {
                throw downloadError ?? RestoreError.modelLoadFailed("模型没有可用下载源")
            }
            completed += Int64(artifact.byteCount)
            if var metrics = downloadMetrics[spec.id] {
                metrics.receivedBytes = Int64(artifact.byteCount)
                metrics.phase = .verifying
                downloadMetrics[spec.id] = metrics
                publishDownloadProgress(for: spec.id)
            }
            RestoreJournal.line("AI 模型下载：\(spec.name) \(index + 1)/\(spec.artifacts.count)")
        }

        RestoreJournal.line("AI 模型文件校验通过：\(spec.name) \(spec.artifacts.count) 个文件")
        try Task.checkCancellation()
        stopDownloadTracking(for: spec.id)
        states[spec.id] = .compiling
        let source = staging.appendingPathComponent(spec.bundleRelativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RestoreError.modelLoadFailed("模型包不完整")
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
        try Task.checkCancellation()
        let record = ReadyRecord(version: spec.version, catalogHash: spec.catalogHash)
        let marker = readyMarker(id: spec.id)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: marker, options: .atomic)
    }

    private func startProgressTimer(for id: RestoreModelID) {
        progressTimers[id]?.cancel()
        progressTimers[id] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.tickDownloadProgress(for: id)
            }
        }
    }

    private func stopDownloadTracking(for id: RestoreModelID) {
        progressTimers[id]?.cancel()
        progressTimers[id] = nil
        downloadMetrics[id] = nil
    }

    private func beginDownloadSource(for id: RestoreModelID, host: String, baselineBytes: Int64, artifactBytes: Int64) -> UUID {
        let now = Date()
        let attemptID = UUID()
        downloadMetrics[id] = DownloadMetrics(
            attemptID: attemptID,
            phase: .connecting,
            sourceHost: host,
            baselineBytes: baselineBytes,
            artifactBytes: artifactBytes,
            receivedBytes: 0,
            startedAt: now,
            lastBytesAt: now,
            lastLoggedAt: now
        )
        publishDownloadProgress(for: id)
        return attemptID
    }

    private func recordDownloadProgress(for id: RestoreModelID, attemptID: UUID, host: String, written: Int64, expected: Int64) {
        guard var metrics = downloadMetrics[id], metrics.attemptID == attemptID, metrics.phase != .verifying else { return }
        let now = Date()
        let expectedBytes = expected > 0 ? min(expected, metrics.artifactBytes) : metrics.artifactBytes
        let received = min(max(0, written), max(0, expectedBytes))
        if received > metrics.receivedBytes {
            metrics.lastBytesAt = now
        }
        metrics.artifactBytes = expectedBytes
        metrics.receivedBytes = received
        metrics.phase = received >= expectedBytes ? .verifying : .downloading
        metrics.sourceHost = host
        downloadMetrics[id] = metrics
        publishDownloadProgress(for: id)
    }

    private func markDownloadVerifying(for id: RestoreModelID) {
        guard var metrics = downloadMetrics[id] else { return }
        metrics.phase = .verifying
        metrics.receivedBytes = metrics.artifactBytes
        metrics.lastBytesAt = Date()
        downloadMetrics[id] = metrics
        publishDownloadProgress(for: id)
    }

    private func tickDownloadProgress(for id: RestoreModelID) {
        guard var metrics = downloadMetrics[id] else { return }
        let now = Date()
        publishDownloadProgress(for: id)
        if now.timeIntervalSince(metrics.lastLoggedAt) >= 10 {
            metrics.lastLoggedAt = now
            downloadMetrics[id] = metrics
            if let progress = currentDownloadProgress(for: id) {
                RestoreJournal.line("AI 模型下载进度：\(progress.summary)")
            }
        }
    }

    private func currentDownloadProgress(for id: RestoreModelID) -> RestoreDownloadProgress? {
        guard let metrics = downloadMetrics[id], let spec = RestoreModelCatalog.spec(for: id) else { return nil }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(metrics.startedAt))
        let idle = max(0, now.timeIntervalSince(metrics.lastBytesAt))
        let received = min(max(0, metrics.baselineBytes + metrics.receivedBytes), Int64(max(0, spec.totalByteCount)))
        let speed = elapsed > 0 ? Double(metrics.receivedBytes) / elapsed : 0
        let remaining: TimeInterval?
        if metrics.phase == .downloading, received > 0, speed > 0, idle < 5 {
            remaining = Double(max(0, Int64(max(0, spec.totalByteCount)) - received)) / speed
        } else {
            remaining = nil
        }
        return RestoreDownloadProgress(
            phase: metrics.phase,
            receivedBytes: received,
            totalBytes: Int64(max(0, spec.totalByteCount)),
            bytesPerSecond: speed,
            elapsedSeconds: elapsed,
            idleSeconds: idle,
            remainingSeconds: remaining,
            sourceHost: metrics.sourceHost
        )
    }

    private func publishDownloadProgress(for id: RestoreModelID) {
        if let progress = currentDownloadProgress(for: id) {
            states[id] = .downloading(progress)
        }
    }

    private func logDownloadInterruption(for id: RestoreModelID, error: Error) {
        guard let progress = currentDownloadProgress(for: id) else { return }
        RestoreJournal.line("AI 模型下载中断：\(progress.summary) · \(error.localizedDescription)")
    }

    private func bundledModelURL(_ spec: RestoreModelSpec) -> URL? {
        let name = URL(fileURLWithPath: spec.bundleRelativePath).deletingPathExtension().lastPathComponent
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
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

    private nonisolated static func sha256(of url: URL) async throws -> String {
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

private final class RestoreModelDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("HiRestore-\(UUID().uuidString)")
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var response: URLResponse?
    private var receivedBytes: Int64 = 0

    init(expectedBytes: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
        super.init()
    }

    func download(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        guard expectedBytes > 0, FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw RestoreError.modelLoadFailed("无法创建模型下载临时文件")
        }
        do {
            fileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.lock()
        self.session = session
        lock.unlock()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        self.response = response
        lock.unlock()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(error: RestoreError.modelLoadFailed("模型服务器返回 HTTP \(http.statusCode)"))
            completionHandler(.cancel)
            return
        }
        onProgress(receivedBytes, expectedBytes)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil, let fileHandle else {
            lock.unlock()
            return
        }
        let remaining = expectedBytes - receivedBytes
        let chunk = data.prefix(min(data.count, Int(remaining)))
        do {
            try fileHandle.write(contentsOf: chunk)
            receivedBytes += Int64(chunk.count)
        } catch {
            lock.unlock()
            finish(error: error)
            return
        }
        let written = receivedBytes
        let complete = written == expectedBytes
        lock.unlock()
        onProgress(written, expectedBytes)
        if complete {
            finish(error: nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionDataTask, didCompleteWithError error: Error?) {
        lock.lock()
        let receivedBytes = self.receivedBytes
        lock.unlock()
        if let error {
            finish(error: error)
        } else if receivedBytes != expectedBytes {
            finish(error: RestoreError.modelLoadFailed("模型下载未完成（已收 \(receivedBytes) / \(expectedBytes) 字节）"))
        } else {
            finish(error: nil)
        }
    }

    private func finish(error: Error?) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        let continuation = self.continuation
        let fileHandle = self.fileHandle
        let response = self.response
        let session = self.session
        let task = self.task
        self.continuation = nil
        self.fileHandle = nil
        self.session = nil
        self.task = nil
        lock.unlock()
        try? fileHandle?.close()
        task?.cancel()
        session?.invalidateAndCancel()
        if let error {
            try? FileManager.default.removeItem(at: fileURL)
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (fileURL, response))
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            continuation?.resume(throwing: RestoreError.modelLoadFailed("模型下载未完成"))
        }
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private struct ReadyRecord: Codable {
    let version: String
    let catalogHash: String
}
