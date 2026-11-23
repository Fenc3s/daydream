import Foundation

enum ObsidianNoteService {
    private struct Registry: Decodable {
        struct VaultEntry: Decodable {
            var path: String
        }
        var vaults: [String: VaultEntry]
    }

    static func noteTitle(from selectedText: String) -> String {
        let title = selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "Untitled"
        let cleanedTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedTitle.isEmpty ? "Untitled" : cleanedTitle
    }

    static func sanitizedRelativeSubfolder(_ subfolder: String) -> String {
        subfolder
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { component in
                component
                    .replacingOccurrences(of: ":", with: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    static func resolveLocalVaultDirectory(
        vaultName: String,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        obsidianRegistryURL: URL? = nil
    ) -> URL? {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let trimmed = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = trimmed.isEmpty ? AppSettings.defaultObsidianVaultName : trimmed

        func existingDirectory(_ url: URL) -> URL? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return url
        }

        if effectiveName.hasPrefix("~/") {
            let relative = String(effectiveName.dropFirst(2))
            return existingDirectory(home.appendingPathComponent(relative, isDirectory: true))
        }
        if effectiveName.hasPrefix("/") {
            return existingDirectory(URL(fileURLWithPath: effectiveName, isDirectory: true))
        }

        let registryURL = obsidianRegistryURL
            ?? home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json", isDirectory: false)
        if let data = try? Data(contentsOf: registryURL),
           let registry = try? JSONDecoder().decode(Registry.self, from: data) {
            for vault in registry.vaults.values {
                let candidateURL = URL(fileURLWithPath: vault.path, isDirectory: true)
                if candidateURL.lastPathComponent.compare(effectiveName, options: [.caseInsensitive]) == .orderedSame,
                   let verified = existingDirectory(candidateURL) {
                    return verified
                }
            }
        }

        let candidates = [
            home
                .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents", isDirectory: true)
                .appendingPathComponent(effectiveName, isDirectory: true),
            home
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(effectiveName, isDirectory: true),
        ]

        for candidate in candidates {
            if let verified = existingDirectory(candidate) {
                return verified
            }
        }
        return nil
    }

    static func writeNoteSilentlyIfPossible(
        content: String,
        selectedText: String,
        vaultName: String,
        subfolder: String,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        obsidianRegistryURL: URL? = nil
    ) throws -> URL? {
        guard let vaultDirectory = resolveLocalVaultDirectory(
            vaultName: vaultName,
            fileManager: fileManager,
            homeDirectory: homeDirectory,
            obsidianRegistryURL: obsidianRegistryURL
        ) else {
            return nil
        }

        let cleanSubfolder = sanitizedRelativeSubfolder(subfolder)
        let targetDirectory = cleanSubfolder.isEmpty
            ? vaultDirectory
            : vaultDirectory.appendingPathComponent(cleanSubfolder, isDirectory: true)
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let fileURL = targetDirectory.appendingPathComponent("\(noteTitle(from: selectedText)).md", isDirectory: false)
        try Data(content.utf8).write(to: fileURL, options: [.atomic])
        return fileURL
    }

    static func fallbackObsidianURL(
        content: String,
        selectedText: String,
        vaultName: String,
        subfolder: String
    ) -> URL? {
        let trimmedVault = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveVault = trimmedVault.isEmpty ? AppSettings.defaultObsidianVaultName : trimmedVault
        let cleanSubfolder = sanitizedRelativeSubfolder(subfolder)
        let title = noteTitle(from: selectedText)
        let fileParameter = cleanSubfolder.isEmpty ? title : "\(cleanSubfolder)/\(title)"

        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "vault", value: effectiveVault),
            URLQueryItem(name: "file", value: fileParameter),
            URLQueryItem(name: "content", value: content),
            URLQueryItem(name: "overwrite", value: "true"),
            URLQueryItem(name: "silent", value: "true"),
        ]
        return components.url
    }
}
