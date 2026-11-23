import AppKit
import Foundation

actor GitVersionService {
    nonisolated let versionLogFileURL: URL
    nonisolated let repositoryURL: URL?

    init(fileManager: FileManager = .default) {
        let logsDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daydream", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        versionLogFileURL = logsDirectory.appendingPathComponent("version-history.log", isDirectory: false)
        if !fileManager.fileExists(atPath: versionLogFileURL.path) {
            fileManager.createFile(atPath: versionLogFileURL.path, contents: Data())
        }

        repositoryURL = Self.discoverRepositoryURL(fileManager: fileManager)
    }

    func captureSnapshot() -> GitVersionSnapshot {
        guard let repositoryURL else {
            return GitVersionSnapshot(
                isAvailable: false,
                availabilityMessage: "No local Git repository was detected for this app session."
            )
        }

        guard let branch = runGit(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], in: repositoryURL),
              let commitHash = runGit(arguments: ["rev-parse", "HEAD"], in: repositoryURL),
              let shortCommitHash = runGit(arguments: ["rev-parse", "--short", "HEAD"], in: repositoryURL) else {
            return GitVersionSnapshot(
                isAvailable: false,
                availabilityMessage: "Git metadata could not be read from the local repository.",
                repositoryPath: repositoryURL.path
            )
        }

        let statusOutput = runGit(arguments: ["status", "--short"], in: repositoryURL) ?? ""
        let statusLines = statusOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let recentCommits = (runGit(arguments: ["log", "--oneline", "-n", "12"], in: repositoryURL) ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        return GitVersionSnapshot(
            isAvailable: true,
            availabilityMessage: "",
            repositoryPath: repositoryURL.path,
            branch: branch,
            commitHash: commitHash,
            shortCommitHash: shortCommitHash,
            isDirty: !statusLines.isEmpty,
            dirtyFiles: statusLines,
            recentCommits: recentCommits
        )
    }

    func recordVersionMarker(reason: String, snapshot: GitVersionSnapshot) {
        guard snapshot.isAvailable else { return }

        let formatter = ISO8601DateFormatter()
        let dirtySummary = snapshot.isDirty ? "dirty(\(snapshot.dirtyFiles.count))" : "clean"

        // The version log is intentionally append-only and human-readable.
        // When a user reports "it worked yesterday" we want one place that
        // answers three rollback questions immediately:
        // 1. Which branch/commit was the app built from?
        // 2. Was the working tree clean or carrying local edits?
        // 3. Which nearby commits are plausible rollback targets?
        //
        // Storing this outside the repository keeps diagnostics available even
        // if the repo later moves, gets reset, or the app is launched from a
        // different working directory.
        var lines: [String] = [
            "",
            "========== \(reason) \(formatter.string(from: Date())) ==========",
            "repo: \(snapshot.repositoryPath)",
            "branch: \(snapshot.branch)",
            "commit: \(snapshot.commitHash)",
            "status: \(dirtySummary)",
        ]

        if !snapshot.dirtyFiles.isEmpty {
            lines.append("dirty_files:")
            lines.append(contentsOf: snapshot.dirtyFiles.map { "  \($0)" })
        }

        if !snapshot.recentCommits.isEmpty {
            lines.append("recent_commits:")
            lines.append(contentsOf: snapshot.recentCommits.map { "  \($0)" })
        }

        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: versionLogFileURL) else {
            return
        }

        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    func readVersionLogTail(maxLength: Int = 24_000) -> String {
        guard let data = try? Data(contentsOf: versionLogFileURL),
              let fullText = String(data: data, encoding: .utf8) else {
            return ""
        }

        guard fullText.count > maxLength else {
            return fullText
        }

        return String(fullText.suffix(maxLength))
    }

    func captureCommitHistory(limit: Int = 100) -> [String] {
        guard let repositoryURL else { return [] }

        let normalizedLimit = min(max(limit, 1), 500)
        return (runGit(
            arguments: [
                "log",
                "--date=short",
                "--pretty=format:%h  %ad  %s",
                "-n",
                "\(normalizedLimit)",
            ],
            in: repositoryURL
        ) ?? "")
        .split(whereSeparator: \.isNewline)
        .map(String.init)
    }

    private func runGit(arguments: [String], in repositoryURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = repositoryURL

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == true ? nil : output
    }

    private static func discoverRepositoryURL(fileManager: FileManager) -> URL? {
        var candidates: [URL] = []

        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(currentDirectory)
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent())

        for candidate in candidates {
            if let repositoryURL = firstGitRepositoryAncestor(startingAt: candidate, fileManager: fileManager) {
                return repositoryURL
            }
        }

        return nil
    }

    private static func firstGitRepositoryAncestor(startingAt startURL: URL, fileManager: FileManager) -> URL? {
        var currentURL = startURL.standardizedFileURL

        while true {
            let gitDirectoryURL = currentURL.appendingPathComponent(".git", isDirectory: true)
            if fileManager.fileExists(atPath: gitDirectoryURL.path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return nil
            }
            currentURL = parentURL
        }
    }
}
