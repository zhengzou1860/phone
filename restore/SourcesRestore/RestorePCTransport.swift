import Foundation
import CryptoKit

enum RestorePCTransport {
    static let defaultEndpoint = "http://192.168.31.100:8719/report"
    static let endpointKey = "hirestore.pcEndpoint"
    static let maximumUploadBytes = 2 * 1024 * 1024 * 1024

    static var savedEndpoint: String {
        UserDefaults.standard.string(forKey: endpointKey) ?? ""
    }

    static func saveEndpoint(_ text: String) {
        UserDefaults.standard.set(text.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey)
    }

    static func normalizedEndpoint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? defaultEndpoint : (trimmed.contains("://") ? trimmed : "http://" + trimmed)
        guard let parts = URLComponents(string: candidate),
              let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        guard parts.port == nil || (parts.port ?? 0) > 0, (parts.port ?? 0) <= 65535 else { return nil }
        return parts.url?.absoluteString
    }

    static func route(_ path: String, endpoint: String) -> URL? {
        guard let target = normalizedEndpoint(endpoint), var parts = URLComponents(string: target) else { return nil }
        parts.path = path
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func encodedFilename(_ filename: String) -> String {
        filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._-"))) ?? "restore.bin"
    }

    static func ping(endpoint: String) async throws -> String {
        guard let url = route("/ping", endpoint: endpoint) else { throw RestorePCError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.timeoutIntervalForResource = 10
        let (data, _) = try await send(request)
        let reply = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "已连接"
        return "连接成功：\(reply)"
    }

    static func sendLog(_ text: String, endpoint: String) async throws -> String {
        guard !text.isEmpty else { throw RestorePCError.emptyLog }
        guard let url = route("/report", endpoint: endpoint) else { throw RestorePCError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.timeoutIntervalForResource = 60
        request.httpBody = Data(text.utf8)
        let (data, _) = try await send(request)
        let reply = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "已接收"
        return "日志已发送（\(request.httpBody?.count ?? 0) 字节）：\(reply)"
    }

    static func upload(
        file: URL,
        endpoint: String,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else { throw RestorePCError.missingFile }
        guard let url = route("/upload", endpoint: endpoint) else { throw RestorePCError.invalidAddress }
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else { throw RestorePCError.emptyFile }
        guard size <= maximumUploadBytes else { throw RestorePCError.fileTooLarge }
        let checksum = try sha256(of: file)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(encodedFilename(file.lastPathComponent), forHTTPHeaderField: "X-HiRestore-Filename")
        request.setValue(String(size), forHTTPHeaderField: "X-HiRestore-Size")
        request.setValue(checksum, forHTTPHeaderField: "X-HiRestore-SHA256")
        request.setValue("1", forHTTPHeaderField: "X-HiRestore-Protocol")
        request.timeoutInterval = 60
        request.timeoutIntervalForResource = 1800

        let tasks = UploadTaskBox()
        let progressTask = Task {
            while !Task.isCancelled {
                let value = tasks.fractionCompleted
                await progress(min(1, max(0, value)))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { progressTask.cancel() }
        let (data, _) = try await send(request, file: file, tasks: tasks)
        await progress(1)
        guard let payload = try? JSONDecoder().decode(UploadReply.self, from: data) else {
            throw RestorePCError.invalidResponse
        }
        return "上传完成：\(payload.filename)（\(RestoreMath.formatBytes(payload.bytes)））"
    }

    private static func send(
        _ request: URLRequest,
        file: URL? = nil,
        tasks: UploadTaskBox? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let result: (Data, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error {
                        continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                        return
                    }
                    guard let response else {
                        continuation.resume(throwing: RestorePCError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), response))
                }
                let task: URLSessionTask
                if let file {
                    task = session.uploadTask(with: request, fromFile: file, completionHandler: completion)
                } else {
                    task = session.dataTask(with: request, completionHandler: completion)
                }
                tasks?.set(task)
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            tasks?.cancel()
        }
        guard let response = result.1 as? HTTPURLResponse else { throw RestorePCError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: result.0, encoding: .utf8) ?? "电脑未返回说明"
            throw RestorePCError.http(response.statusCode, message)
        }
        return (result.0, response)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct UploadReply: Decodable {
    let status: String
    let filename: String
    let bytes: Int
}

private final class UploadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        lock.unlock()
    }

    var fractionCompleted: Double {
        lock.lock()
        defer { lock.unlock() }
        return task?.progress.fractionCompleted ?? 0
    }
}

enum RestorePCError: LocalizedError {
    case invalidAddress
    case emptyLog
    case missingFile
    case emptyFile
    case fileTooLarge
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "电脑地址无效，请填写 IP、端口和 /report，例如 \(RestorePCTransport.defaultEndpoint)"
        case .emptyLog:
            return "运行日志还是空的"
        case .missingFile:
            return "要上传的修复结果已不存在"
        case .emptyFile:
            return "修复结果是空文件，无法上传"
        case .fileTooLarge:
            return "修复结果超过 2 GB，请通过文件 App 或分享导出"
        case .invalidResponse:
            return "电脑没有返回有效的接收回执"
        case .http(let code, let message):
            return "电脑返回 HTTP \(code)：\(message)"
        }
    }
}
