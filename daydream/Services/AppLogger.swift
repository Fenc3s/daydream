import Foundation

actor AppLogger {
    static let defaultMaxLogFileBytes = 5 * 1024 * 1024
    static let shared = AppLogger()

    nonisolated let logFileURL: URL
    nonisolated let rotatedLogFileURL: URL
    private let fileManager: FileManager
    private let maxLogFileBytes: Int
    private let isoFormatter = ISO8601DateFormatter()

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        maxLogFileBytes: Int = AppLogger.defaultMaxLogFileBytes
    ) {
        self.fileManager = fileManager
        self.maxLogFileBytes = max(1_024, maxLogFileBytes)
        let baseDirectory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daydream", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        logFileURL = baseDirectory.appendingPathComponent("daydream.log", isDirectory: false)
        rotatedLogFileURL = baseDirectory.appendingPathComponent("daydream.log.1", isDirectory: false)
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: Data())
        }

        let launchLine = "\n========== daydream launch \(isoFormatter.string(from: Date())) ==========\n"
        if let data = launchLine.data(using: .utf8) {
            Self.rotateAndAppend(
                data: data,
                logFileURL: logFileURL,
                rotatedLogFileURL: rotatedLogFileURL,
                maxBytes: self.maxLogFileBytes,
                fileManager: fileManager
            )
        }
    }

    func log(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        let metadataText = metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: "\\n"))" }
            .joined(separator: " ")
        let line = "[\(isoFormatter.string(from: Date()))] [\(category)] \(message)\(metadataText.isEmpty ? "" : " \(metadataText)")\n"

        guard let data = line.data(using: .utf8) else { return }
        Self.rotateAndAppend(
            data: data,
            logFileURL: logFileURL,
            rotatedLogFileURL: rotatedLogFileURL,
            maxBytes: maxLogFileBytes,
            fileManager: fileManager
        )
    }

    func readLogTail(maxLength: Int = 48_000) -> String {
        let currentText = (try? Data(contentsOf: logFileURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if currentText.count >= maxLength {
            return String(currentText.suffix(maxLength))
        }

        let remaining = maxLength - currentText.count
        guard remaining > 0,
              let rotatedData = try? Data(contentsOf: rotatedLogFileURL),
              let rotatedText = String(data: rotatedData, encoding: .utf8),
              !rotatedText.isEmpty else {
            return currentText
        }

        let rotatedTail = rotatedText.count > remaining ? String(rotatedText.suffix(remaining)) : rotatedText
        return rotatedTail + currentText
    }

    private static func rotateAndAppend(
        data: Data,
        logFileURL: URL,
        rotatedLogFileURL: URL,
        maxBytes: Int,
        fileManager: FileManager
    ) {
        let currentSize = (try? logFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if currentSize > 0, currentSize + data.count > maxBytes {
            try? fileManager.removeItem(at: rotatedLogFileURL)
            try? fileManager.moveItem(at: logFileURL, to: rotatedLogFileURL)
            fileManager.createFile(atPath: logFileURL.path, contents: Data())
        } else if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: Data())
        }

        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
