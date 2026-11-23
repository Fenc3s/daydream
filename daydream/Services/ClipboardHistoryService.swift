import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ClipboardHistoryService {
    private static let maxSavedFileSizeInBytes = 5 * 1024 * 1024

    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    private let onEntryCaptured: (ClipboardHistoryEntry) -> Void
    private let makeRetention: () -> ClipboardHistoryRetention
    private let store: ClipboardHistoryStore

    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastFingerprint: String?
    private var ignoredFingerprint: String?
    private var shouldIgnoreNextCapture = false

    init(
        pasteboard: NSPasteboard = .general,
        pollInterval: TimeInterval = 0.75,
        store: ClipboardHistoryStore = ClipboardHistoryStore(),
        makeRetention: @escaping () -> ClipboardHistoryRetention,
        onEntryCaptured: @escaping (ClipboardHistoryEntry) -> Void
    ) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.store = store
        self.makeRetention = makeRetention
        self.onEntryCaptured = onEntryCaptured
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }

        let scheduled = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureIfNeeded()
            }
        }
        scheduled.tolerance = min(0.25, pollInterval * 0.3)
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func loadPersistedSummaries(
        searchText: String,
        filter: ClipboardContentType,
        offset: Int,
        limit: Int
    ) async -> [ClipboardHistorySummary] {
        await store.loadSummaries(searchText: searchText, filter: filter, offset: offset, limit: limit)
    }

    func countPersistedSummaries(searchText: String, filter: ClipboardContentType) async -> Int {
        await store.countSummaries(searchText: searchText, filter: filter)
    }

    func loadPersistedEntry(id: UUID) async -> ClipboardHistoryEntry? {
        guard let entry = await store.loadEntry(id: id) else {
            return nil
        }
        return entry.capturedAt >= Date().addingTimeInterval(-makeRetention().maxAge) ? entry : nil
    }

    func upsert(_ entry: ClipboardHistoryEntry) async {
        guard entry.capturedAt >= Date().addingTimeInterval(-makeRetention().maxAge) else { return }
        await store.upsert(entry)
    }

    func clear() async {
        await store.clear()
    }

    func prunePersistedEntries() async {
        let cutoffDate = Date().addingTimeInterval(-makeRetention().maxAge)
        await store.prune(olderThan: cutoffDate)
    }

    func ignoreNextCapture(for fingerprint: String) {
        ignoredFingerprint = fingerprint
    }

    func ignoreNextCapture() {
        shouldIgnoreNextCapture = true
    }

    func captureCurrentClipboard() {
        lastChangeCount = pasteboard.changeCount
        recordCurrentClipboardIfNeeded()
    }

    private func captureIfNeeded() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        recordCurrentClipboardIfNeeded()
    }

    private func recordCurrentClipboardIfNeeded() {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let sourceAppName = frontmostApplication?.localizedName ?? "Unknown App"
        let sourceAppBundleIdentifier = frontmostApplication?.bundleIdentifier

        let fileURLs = ((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? [])
            .filter(\.isFileURL)

        if !fileURLs.isEmpty {
            guard fileURLs.allSatisfy(isSavableClipboardFile) else { return }
            let snapshot = PasteboardSnapshot.limitedCapture(from: pasteboard)
            guard !snapshot.items.isEmpty else { return }

            let title = fileURLs.count == 1 ? fileURLs[0].lastPathComponent : "\(fileURLs.count) Files"
            let subtitle = fileURLs.prefix(3).map(\.path).joined(separator: "\n")
            let entry = ClipboardHistoryEntry(
                capturedAt: Date(),
                sourceAppName: sourceAppName,
                sourceAppBundleIdentifier: sourceAppBundleIdentifier,
                contentType: .file,
                title: title,
                subtitle: subtitle,
                plainText: fileURLs.map(\.path).joined(separator: "\n"),
                imageData: nil,
                imagePreview: nil,
                fileURLs: fileURLs,
                snapshot: snapshot,
                fingerprint: Self.fingerprint(forFileURLs: fileURLs)
            )
            deliverCapturedEntryIfNeeded(entry)
            return
        }

        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .newlines),
           !string.isEmpty {
            let contentType: ClipboardContentType = URL(string: string)?.scheme == nil ? .text : .link
            let snapshot = PasteboardSnapshot.plainText(string)
            let entry = ClipboardHistoryEntry(
                capturedAt: Date(),
                sourceAppName: sourceAppName,
                sourceAppBundleIdentifier: sourceAppBundleIdentifier,
                contentType: contentType,
                title: summarizeText(string),
                subtitle: textSubtitle(for: string),
                plainText: string,
                imageData: nil,
                imagePreview: nil,
                fileURLs: [],
                snapshot: snapshot,
                fingerprint: Self.fingerprint(forText: string, contentType: contentType)
            )
            deliverCapturedEntryIfNeeded(entry)
            return
        }

        if let image = NSImage(pasteboard: pasteboard) {
            let size = image.size
            let tiffData = image.tiffRepresentation
            let capturedSnapshot = PasteboardSnapshot.limitedCapture(from: pasteboard)
            let capturedAt = Date()
            if shouldIgnoreNextCapture {
                shouldIgnoreNextCapture = false
                return
            }

            Task.detached(priority: .utility) { [weak self] in
                let encodedData = tiffData.flatMap(Self.encodedImageData(fromTIFFData:))
                let snapshot = !capturedSnapshot.items.isEmpty
                    ? capturedSnapshot
                    : encodedData.map { PasteboardSnapshot.singleType(NSPasteboard.PasteboardType(UTType.webP.identifier), data: $0) } ?? capturedSnapshot
                guard !snapshot.items.isEmpty else { return }
                let computedFingerprint = encodedData.map(Self.fingerprint(forData:)) ?? Self.fingerprint(for: snapshot)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let previewImage = encodedData.flatMap(NSImage.init(data:)) ?? tiffData.flatMap(NSImage.init(data:))
                    let entry = ClipboardHistoryEntry(
                        capturedAt: capturedAt,
                        sourceAppName: sourceAppName,
                        sourceAppBundleIdentifier: sourceAppBundleIdentifier,
                        contentType: .image,
                        title: "Image (\(Int(size.width))×\(Int(size.height)))",
                        subtitle: "Copied from \(sourceAppName)",
                        plainText: nil,
                        imageData: encodedData,
                        imagePreview: previewImage,
                        fileURLs: [],
                        snapshot: snapshot,
                        fingerprint: computedFingerprint
                    )
                    self.deliverCapturedEntryIfNeeded(entry, allowIgnoreFlagConsumption: false)
                }
            }
            return
        }

        let snapshot = PasteboardSnapshot.limitedCapture(from: pasteboard)
        guard !snapshot.items.isEmpty else { return }
        let primaryTypes = snapshot.items.flatMap(\.keys).map(\.rawValue).prefix(4).joined(separator: ", ")
        let entry = ClipboardHistoryEntry(
            capturedAt: Date(),
            sourceAppName: sourceAppName,
            sourceAppBundleIdentifier: sourceAppBundleIdentifier,
            contentType: .other,
            title: "Clipboard Item",
            subtitle: primaryTypes.isEmpty ? nil : primaryTypes,
            plainText: nil,
            imageData: nil,
            imagePreview: nil,
            fileURLs: [],
            snapshot: snapshot,
            fingerprint: Self.fingerprint(for: snapshot)
        )
        deliverCapturedEntryIfNeeded(entry)
    }

    private func deliverCapturedEntryIfNeeded(_ entry: ClipboardHistoryEntry, allowIgnoreFlagConsumption: Bool = true) {
        if allowIgnoreFlagConsumption, shouldIgnoreNextCapture {
            shouldIgnoreNextCapture = false
            lastFingerprint = entry.fingerprint
            return
        }
        if entry.fingerprint == ignoredFingerprint {
            ignoredFingerprint = nil
            lastFingerprint = entry.fingerprint
            return
        }
        guard entry.fingerprint != lastFingerprint else { return }

        lastFingerprint = entry.fingerprint
        onEntryCaptured(entry)
    }

    private func summarizeText(_ text: String) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "Empty Text" }
        if flattened.count <= 60 {
            return flattened
        }
        return String(flattened.prefix(60)) + "…"
    }

    private func textSubtitle(for text: String) -> String {
        let characterCount = text.count
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        return "\(characterCount) chars • \(wordCount) words"
    }

    nonisolated private static func encodedImageData(fromTIFFData tiffData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(tiffData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let webPData = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(
            webPData,
            UTType.webP.identifier as CFString,
            1,
            nil
        ) {
            let options = [
                kCGImageDestinationLossyCompressionQuality: 0.82,
            ] as CFDictionary
            CGImageDestinationAddImage(destination, cgImage, options)
            if CGImageDestinationFinalize(destination) {
                return webPData as Data
            }
        }

        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func isSavableClipboardFile(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                return false
            }
            return fileSize <= Self.maxSavedFileSizeInBytes
        } catch {
            return false
        }
    }

    nonisolated private static func fingerprint(for snapshot: PasteboardSnapshot) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("snapshot".utf8))
        for item in snapshot.items {
            let types = item.keys.map(\.rawValue).sorted()
            for type in types {
                hasher.update(data: Data(type.utf8))
                if let data = item[NSPasteboard.PasteboardType(type)] {
                    hasher.update(data: data)
                }
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func fingerprint(forText text: String, contentType: ClipboardContentType) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(contentType.rawValue.utf8))
        hasher.update(data: Data(text.utf8))
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func fingerprint(forFileURLs fileURLs: [URL]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("files".utf8))
        for path in fileURLs.map(\.path).sorted() {
            hasher.update(data: Data(path.utf8))
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func fingerprint(forData data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("data".utf8))
        hasher.update(data: data)
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
