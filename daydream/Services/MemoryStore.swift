import Foundation
import NaturalLanguage

enum MemoryTokenizer {
    private static let cjkStopCharacters: Set<Character> = Set("的了是在有和与或把被将让给对从向到于及等之个着过吗呢吧啊呀")

    static func tokens(from text: String) -> Set<String> {
        let normalized = text.lowercased()
        guard !normalized.isEmpty else { return [] }

        var result: Set<String> = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let word = String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return true }
            if containsCJKOrNonASCIIWordScalar(word) {
                let filtered = String(word.filter { !cjkStopCharacters.contains($0) })
                if filtered.count >= 2 {
                    result.insert(filtered)
                }
            } else if word.count >= 3, word.allSatisfy({ $0.isLetter || $0.isNumber }) {
                result.insert(word)
            }
            return true
        }

        // Add overlapping CJK character bigrams so compound Chinese phrases match reliably across variations.
        var cjkRun: [Character] = []
        func flushRun() {
            defer { cjkRun.removeAll(keepingCapacity: true) }
            guard cjkRun.count >= 2 else { return }
            for index in 0..<(cjkRun.count - 1) {
                result.insert(String([cjkRun[index], cjkRun[index + 1]]))
            }
        }
        for char in normalized {
            if isCJKIdeograph(char), !cjkStopCharacters.contains(char) {
                cjkRun.append(char)
            } else {
                flushRun()
            }
        }
        flushRun()

        return result
    }

    private static func containsCJKOrNonASCIIWordScalar(_ word: String) -> Bool {
        word.unicodeScalars.contains { scalar in
            scalar.value > 0x7F && (CharacterSet.letters.contains(scalar) || scalar.properties.isIdeographic)
        }
    }

    private static func isCJKIdeograph(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isIdeographic }
    }
}

struct MemoryStoreSnapshot: Codable, Equatable, Sendable {
    var entries: [AIMemoryEntry]
}

final class MemoryStore {
    let fileURL: URL

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daydream", isDirectory: true)
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        fileURL = baseDirectory.appendingPathComponent("memory.json", isDirectory: false)
    }

    func load() -> MemoryStoreSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(MemoryStoreSnapshot.self, from: data) else {
            return MemoryStoreSnapshot(entries: [])
        }
        return snapshot
    }

    func save(_ snapshot: MemoryStoreSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
