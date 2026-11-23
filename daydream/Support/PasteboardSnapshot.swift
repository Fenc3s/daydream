import AppKit
import Foundation

struct PasteboardSnapshot: Codable, Equatable, Sendable {
    static let maxCapturedTypeBytes = 5 * 1024 * 1024
    static let maxCapturedSnapshotBytes = 10 * 1024 * 1024

    var items: [[NSPasteboard.PasteboardType: Data]]

    init(items: [[NSPasteboard.PasteboardType: Data]]) {
        self.items = items
    }

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        capture(from: pasteboard, maxTypeBytes: nil, maxSnapshotBytes: nil)
    }

    static func limitedCapture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        capture(
            from: pasteboard,
            maxTypeBytes: maxCapturedTypeBytes,
            maxSnapshotBytes: maxCapturedSnapshotBytes
        )
    }

    static func plainText(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [[.string: Data(text.utf8)]])
    }

    static func singleType(_ type: NSPasteboard.PasteboardType, data: Data) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [[type: data]])
    }

    private static func capture(
        from pasteboard: NSPasteboard,
        maxTypeBytes: Int?,
        maxSnapshotBytes: Int?
    ) -> PasteboardSnapshot {
        var capturedBytes = 0
        let items = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                if let maxTypeBytes, data.count > maxTypeBytes {
                    return nil
                }
                if let maxSnapshotBytes, capturedBytes + data.count > maxSnapshotBytes {
                    return nil
                }
                capturedBytes += data.count
                return (type, data)
            })
        }
            .filter { !$0.isEmpty } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !items.isEmpty else { return }

        let restoredItems = items.map { typeMap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typeMap {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decodedItems = try container.decode([[String: Data]].self)
        items = decodedItems.map { item in
            Dictionary(uniqueKeysWithValues: item.map { (NSPasteboard.PasteboardType($0.key), $0.value) })
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let encodedItems = items.map { item in
            Dictionary(uniqueKeysWithValues: item.map { ($0.key.rawValue, $0.value) })
        }
        try container.encode(encodedItems)
    }
}
