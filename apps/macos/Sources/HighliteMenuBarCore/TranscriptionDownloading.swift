import Darwin
import Foundation

public protocol TranscriptionDownloading: Sendable {
    func download(
        _ artifact: TranscriptionArtifact,
        to destination: URL,
        progress: @escaping @Sendable (_ completed: Int64, _ total: Int64) -> Void
    ) async throws
}

public struct URLSessionArtifactDownloader: TranscriptionDownloading {
    public init() {}

    public func download(
        _ artifact: TranscriptionArtifact,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let delegate = ArtifactDownloadDelegate(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: artifact.url)
        request.httpMethod = "GET"
        request.setValue("Highlite/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let task = session.downloadTask(with: request)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.attach(continuation: continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
    }
}

private final class ArtifactDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var downloaded = false
    private var completionError: Error?
    private var finished = false
    private var lastProgressAt = Date.distantPast
    private var lastProgressBytes: Int64 = 0

    init(
        destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.destination = destination
        self.progress = progress
    }

    func attach(
        continuation: CheckedContinuation<Void, Error>
    ) {
        lock.lock()
        self.continuation = continuation
        self.lastProgressAt = .distantPast
        self.lastProgressBytes = 0
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = max(0, totalBytesExpectedToWrite)
        let now = Date()
        let significant = total > 0 && (totalBytesWritten - lastProgressBytes) * 50 >= total
        let isComplete = total > 0 && totalBytesWritten >= total
        guard significant || isComplete || now.timeIntervalSince(lastProgressAt) >= 0.25 else {
            return
        }
        lastProgressAt = now
        lastProgressBytes = totalBytesWritten
        progress(totalBytesWritten, total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            completionError = TranscriptionProvisioningError.downloadFailed(
                "HTTP \(response.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "the download")."
            )
            return
        }
        do {
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            downloaded = true
        } catch {
            completionError = TranscriptionProvisioningError.downloadFailed(
                "Could not save \(destination.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let savedError = completionError
        let didDownload = downloaded
        lock.unlock()

        if let error {
            continuation?.resume(throwing: error)
            return
        }
        if let savedError {
            continuation?.resume(throwing: savedError)
            return
        }
        guard didDownload else {
            continuation?.resume(
                throwing: TranscriptionProvisioningError.downloadFailed(
                    "The download completed without a file."
                )
            )
            return
        }
        continuation?.resume()
    }
}

public protocol TranscriptionArchiveExtracting: Sendable {
    func extract(archive: URL, to directory: URL) async throws
}

public struct SystemTarArchiveExtractor: TranscriptionArchiveExtracting {
    public init() {}

    public func extract(archive: URL, to directory: URL) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", directory.path],
            timeout: 180
        )
        guard result.status == 0 else {
            throw TranscriptionProvisioningError.extractionFailed(
                result.stderr.isEmpty ? "tar exited with status \(result.status)." : result.stderr
            )
        }
    }
}

public protocol TranscriptionValidating: Sendable {
    func validate(installation: TranscriptionInstallation) async throws
}

public struct CommandLineTranscriptionValidator: TranscriptionValidating {
    public init() {}

    public func validate(installation: TranscriptionInstallation) async throws {
        let info = try await ProcessRunner.run(
            executable: installation.parakeetBinary,
            arguments: ["info", installation.model.path],
            timeout: 180
        )
        guard info.status == 0 else {
            throw TranscriptionProvisioningError.validationFailed(
                info.stderr.isEmpty
                    ? "parakeet-cli info exited with status \(info.status)."
                    : info.stderr
            )
        }
        let decoder = try await ProcessRunner.run(
            executable: installation.ffmpeg,
            arguments: ["-hide_banner", "-version"],
            timeout: 30
        )
        guard decoder.status == 0 else {
            throw TranscriptionProvisioningError.validationFailed(
                decoder.stderr.isEmpty
                    ? "ffmpeg exited with status \(decoder.status)."
                    : decoder.stderr
            )
        }
    }
}

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let control = ProcessControl(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stdout = ProcessOutputBuffer()
                let stderr = ProcessOutputBuffer()
                let readers = DispatchGroup()
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }

                let state = ProcessRunState(continuation: continuation)
                control.attach(state)
                guard !control.isCancelled else {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    state.finish(error: CancellationError())
                    return
                }
                process.terminationHandler = { finished in
                    readers.wait()
                    state.finish(
                        result: ProcessResult(
                            status: finished.terminationStatus,
                            stdout: stdout.string,
                            stderr: stderr.string
                        )
                    )
                }

                do {
                    try process.run()
                } catch {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    state.finish(error: error)
                    return
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard state.timedOutIfRunning(process) else { return }
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var state: ProcessRunState?
    private var cancelled = false

    init(process: Process) {
        self.process = process
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ state: ProcessRunState) {
        lock.lock()
        self.state = state
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled {
            state.cancel()
            if process.isRunning {
                process.terminate()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let state = self.state
        lock.unlock()
        state?.cancel()
        let process = self.process
        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var timedOut = false
    private var cancelled = false

    init(continuation: CheckedContinuation<ProcessResult, Error>) {
        self.continuation = continuation
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func timedOutIfRunning(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return false }
        timedOut = true
        return true
    }

    func finish(result: ProcessResult) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let didTimeOut = timedOut
        let wasCancelled = cancelled
        lock.unlock()
        guard let continuation else { return }
        if wasCancelled {
            continuation.resume(throwing: CancellationError())
        } else if didTimeOut {
            continuation.resume(
                throwing: TranscriptionProvisioningError.validationFailed(
                    "a helper process timed out"
                )
            )
        } else {
            continuation.resume(returning: result)
        }
    }

    func finish(error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: error)
        }
    }
}
