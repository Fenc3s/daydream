import AppKit
import Foundation
import SQLite3

actor ClipboardHistoryStore {
    nonisolated let databaseURL: URL
    nonisolated let legacyFileURL: URL
    private var database: OpaquePointer?
    private var didInitializeDatabase = false

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        let baseDirectory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daydream", isDirectory: true)
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        databaseURL = baseDirectory.appendingPathComponent("clipboard-history.sqlite", isDirectory: false)
        legacyFileURL = baseDirectory.appendingPathComponent("clipboard-history.json", isDirectory: false)
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func loadSummaries(
        searchText: String,
        filter: ClipboardContentType,
        offset: Int,
        limit: Int
    ) -> [ClipboardHistorySummary] {
        initializeDatabaseIfNeeded()
        return withDatabase { db in
            let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let statement: OpaquePointer?

            if normalizedSearchText.isEmpty {
                let sql = """
                SELECT id, captured_at, source_app_name, source_app_bundle_identifier, content_type, title, subtitle, plain_text, fingerprint
                FROM clipboard_history_summary
                WHERE (? = ? OR content_type = ?)
                ORDER BY captured_at DESC
                LIMIT ? OFFSET ?;
                """
                statement = prepareStatement(db, sql: sql)
                bindText(filter.rawValue, to: 1, in: statement)
                bindText(ClipboardContentType.all.rawValue, to: 2, in: statement)
                bindText(filter.rawValue, to: 3, in: statement)
                sqlite3_bind_int64(statement, 4, sqlite3_int64(limit))
                sqlite3_bind_int64(statement, 5, sqlite3_int64(offset))
            } else if normalizedSearchText.count >= 3, hasFTSTable(in: db) {
                let sql = """
                SELECT s.id, s.captured_at, s.source_app_name, s.source_app_bundle_identifier, s.content_type, s.title, s.subtitle, s.plain_text, s.fingerprint
                FROM clipboard_history_summary s
                JOIN clipboard_history_fts f ON f.id = s.id
                WHERE clipboard_history_fts MATCH ?
                  AND (? = ? OR s.content_type = ?)
                ORDER BY s.captured_at DESC
                LIMIT ? OFFSET ?;
                """
                statement = prepareStatement(db, sql: sql)
                bindText(ftsTrigramQuery(for: normalizedSearchText), to: 1, in: statement)
                bindText(filter.rawValue, to: 2, in: statement)
                bindText(ClipboardContentType.all.rawValue, to: 3, in: statement)
                bindText(filter.rawValue, to: 4, in: statement)
                sqlite3_bind_int64(statement, 5, sqlite3_int64(limit))
                sqlite3_bind_int64(statement, 6, sqlite3_int64(offset))
            } else {
                let sql = """
                SELECT id, captured_at, source_app_name, source_app_bundle_identifier, content_type, title, subtitle, plain_text, fingerprint
                FROM clipboard_history_summary
                WHERE search_text LIKE ? ESCAPE '\\'
                  AND (? = ? OR content_type = ?)
                ORDER BY captured_at DESC
                LIMIT ? OFFSET ?;
                """
                statement = prepareStatement(db, sql: sql)
                bindText(likePattern(for: normalizedSearchText), to: 1, in: statement)
                bindText(filter.rawValue, to: 2, in: statement)
                bindText(ClipboardContentType.all.rawValue, to: 3, in: statement)
                bindText(filter.rawValue, to: 4, in: statement)
                sqlite3_bind_int64(statement, 5, sqlite3_int64(limit))
                sqlite3_bind_int64(statement, 6, sqlite3_int64(offset))
            }

            guard let statement else { return [] }
            defer { sqlite3_finalize(statement) }

            var results: [ClipboardHistorySummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idString = columnText(at: 0, in: statement),
                      let id = UUID(uuidString: idString),
                      let contentTypeRaw = columnText(at: 4, in: statement),
                      let contentType = ClipboardContentType(rawValue: contentTypeRaw)
                else { continue }

                let capturedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                results.append(
                    ClipboardHistorySummary(
                        id: id,
                        capturedAt: capturedAt,
                        sourceAppName: columnText(at: 2, in: statement) ?? "Unknown App",
                        sourceAppBundleIdentifier: columnText(at: 3, in: statement),
                        contentType: contentType,
                        title: columnText(at: 5, in: statement) ?? "",
                        subtitle: columnText(at: 6, in: statement),
                        plainText: columnText(at: 7, in: statement),
                        fileURLs: [],
                        fingerprint: columnText(at: 8, in: statement) ?? ""
                    )
                )
            }
            return results
        } ?? []
    }

    func countSummaries(searchText: String, filter: ClipboardContentType) -> Int {
        initializeDatabaseIfNeeded()
        return withDatabase { db in
            let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let statement: OpaquePointer?

            if normalizedSearchText.isEmpty {
                let sql = """
                SELECT COUNT(*)
                FROM clipboard_history_summary
                WHERE (? = ? OR content_type = ?);
                """
                statement = prepareStatement(db, sql: sql)
                bindText(filter.rawValue, to: 1, in: statement)
                bindText(ClipboardContentType.all.rawValue, to: 2, in: statement)
                bindText(filter.rawValue, to: 3, in: statement)
            } else if normalizedSearchText.count >= 3, hasFTSTable(in: db) {
                let sql = """
                SELECT COUNT(*)
                FROM clipboard_history_summary s
                JOIN clipboard_history_fts f ON f.id = s.id
                WHERE clipboard_history_fts MATCH ?
                  AND (? = ? OR s.content_type = ?);
                """
                statement = prepareStatement(db, sql: sql)
                bindText(ftsTrigramQuery(for: normalizedSearchText), to: 1, in: statement)
                bindText(filter.rawValue, to: 2, in: statement)
                bindText(ClipboardContentType.all.rawValue, to: 3, in: statement)
                bindText(filter.rawValue, to: 4, in: statement)
            } else {
                let sql = """
                SELECT COUNT(*)
                FROM clipboard_history_summary
                WHERE search_text LIKE ? ESCAPE '\\'
                  AND (? = ? OR content_type = ?);
                """
                statement = prepareStatement(db, sql: sql)
                bindText(likePattern(for: normalizedSearchText), to: 1, in: statement)
                bindText(filter.rawValue, to: 2, in: statement)
                bindText(ClipboardContentType.all.rawValue, to: 3, in: statement)
                bindText(filter.rawValue, to: 4, in: statement)
            }

            guard let statement else { return 0 }
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        } ?? 0
    }

    func loadEntry(id: UUID) -> ClipboardHistoryEntry? {
        initializeDatabaseIfNeeded()
        return withDatabase { db in
            let sql = """
            SELECT s.id, s.captured_at, s.source_app_name, s.source_app_bundle_identifier, s.content_type,
                   s.title, s.subtitle, s.plain_text, s.fingerprint,
                   p.image_data,
                   CASE
                       WHEN s.content_type IN (?, ?, ?) THEN NULL
                       ELSE p.snapshot_data
                   END AS snapshot_data,
                   p.file_urls_data
            FROM clipboard_history_summary s
            JOIN clipboard_history_payload p ON p.id = s.id
            WHERE s.id = ?
            LIMIT 1;
            """

            guard let statement = prepareStatement(db, sql: sql) else { return nil }
            defer { sqlite3_finalize(statement) }
            bindText(ClipboardContentType.text.rawValue, to: 1, in: statement)
            bindText(ClipboardContentType.link.rawValue, to: 2, in: statement)
            bindText(ClipboardContentType.image.rawValue, to: 3, in: statement)
            bindText(id.uuidString, to: 4, in: statement)

            guard sqlite3_step(statement) == SQLITE_ROW,
                  let idString = columnText(at: 0, in: statement),
                  let entryID = UUID(uuidString: idString),
                  let contentTypeRaw = columnText(at: 4, in: statement),
                  let contentType = ClipboardContentType(rawValue: contentTypeRaw),
                  let fileURLsData = columnData(at: 11, in: statement),
                  let fileURLs = decodeFileURLs(from: fileURLsData)
            else { return nil }

            let imageData = columnData(at: 9, in: statement)
            let plainText = columnText(at: 7, in: statement)
            let snapshot = lightweightSnapshot(
                contentType: contentType,
                plainText: plainText,
                imageData: imageData,
                snapshotData: columnData(at: 10, in: statement)
            )
            return ClipboardHistoryEntry(
                id: entryID,
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                sourceAppName: columnText(at: 2, in: statement) ?? "Unknown App",
                sourceAppBundleIdentifier: columnText(at: 3, in: statement),
                contentType: contentType,
                title: columnText(at: 5, in: statement) ?? "",
                subtitle: columnText(at: 6, in: statement),
                plainText: plainText,
                imageData: imageData,
                imagePreview: imageData.flatMap(NSImage.init(data:)),
                fileURLs: fileURLs,
                snapshot: snapshot,
                fingerprint: columnText(at: 8, in: statement) ?? ""
            )
        }
    }

    func upsert(_ entry: ClipboardHistoryEntry) {
        initializeDatabaseIfNeeded()
        withDatabase { db in
            let summaryID = existingID(forFingerprint: entry.fingerprint, in: db) ?? entry.id
            let summarySQL = """
            INSERT INTO clipboard_history_summary (
                id, captured_at, source_app_name, source_app_bundle_identifier, content_type,
                title, subtitle, plain_text, fingerprint, search_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                captured_at = excluded.captured_at,
                source_app_name = excluded.source_app_name,
                source_app_bundle_identifier = excluded.source_app_bundle_identifier,
                content_type = excluded.content_type,
                title = excluded.title,
                subtitle = excluded.subtitle,
                plain_text = excluded.plain_text,
                fingerprint = excluded.fingerprint,
                search_text = excluded.search_text;
            """

            let payloadSQL = """
            INSERT INTO clipboard_history_payload (
                id, image_data, snapshot_data, file_urls_data
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                image_data = excluded.image_data,
                snapshot_data = excluded.snapshot_data,
                file_urls_data = excluded.file_urls_data;
            """

            guard let summaryStatement = prepareStatement(db, sql: summarySQL),
                  let payloadStatement = prepareStatement(db, sql: payloadSQL),
                  let snapshotData = encodeSnapshot(entry.snapshot),
                  let fileURLsData = encodeFileURLs(entry.fileURLs)
            else { return }
            defer {
                sqlite3_finalize(summaryStatement)
                sqlite3_finalize(payloadStatement)
            }

            sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil)

            bindText(summaryID.uuidString, to: 1, in: summaryStatement)
            sqlite3_bind_double(summaryStatement, 2, entry.capturedAt.timeIntervalSince1970)
            bindText(entry.sourceAppName, to: 3, in: summaryStatement)
            bindText(entry.sourceAppBundleIdentifier, to: 4, in: summaryStatement)
            bindText(entry.contentType.rawValue, to: 5, in: summaryStatement)
            bindText(entry.title, to: 6, in: summaryStatement)
            bindText(entry.subtitle, to: 7, in: summaryStatement)
            bindText(entry.plainText, to: 8, in: summaryStatement)
            bindText(entry.fingerprint, to: 9, in: summaryStatement)
            bindText(searchText(for: entry), to: 10, in: summaryStatement)

            if sqlite3_step(summaryStatement) != SQLITE_DONE {
                sqlite3_exec(db, "ROLLBACK TRANSACTION", nil, nil, nil)
                return
            }

            bindText(summaryID.uuidString, to: 1, in: payloadStatement)
            bindData(entry.imageData, to: 2, in: payloadStatement)
            bindData(snapshotData, to: 3, in: payloadStatement)
            bindData(fileURLsData, to: 4, in: payloadStatement)

            if sqlite3_step(payloadStatement) != SQLITE_DONE {
                sqlite3_exec(db, "ROLLBACK TRANSACTION", nil, nil, nil)
                return
            }

            sqlite3_exec(db, "COMMIT TRANSACTION", nil, nil, nil)
        }
    }

    func clear() {
        initializeDatabaseIfNeeded()
        withDatabase { db in
            sqlite3_exec(db, "DELETE FROM clipboard_history_payload;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM clipboard_history_summary;", nil, nil, nil)
        }
    }

    func prune(olderThan cutoffDate: Date) {
        initializeDatabaseIfNeeded()
        withDatabase { db in
            guard let statement = prepareStatement(db, sql: "DELETE FROM clipboard_history_summary WHERE captured_at < ?;") else {
                return
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoffDate.timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }

    private func initializeDatabaseIfNeeded() {
        guard !didInitializeDatabase else { return }
        didInitializeDatabase = true
        withDatabase { db in
            sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)

            sqlite3_exec(
                db,
                """
                CREATE TABLE IF NOT EXISTS clipboard_history_summary (
                    id TEXT PRIMARY KEY,
                    captured_at REAL NOT NULL,
                    source_app_name TEXT NOT NULL,
                    source_app_bundle_identifier TEXT,
                    content_type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    subtitle TEXT,
                    plain_text TEXT,
                    fingerprint TEXT NOT NULL UNIQUE,
                    search_text TEXT NOT NULL
                );
                """,
                nil,
                nil,
                nil
            )

            sqlite3_exec(
                db,
                """
                CREATE TABLE IF NOT EXISTS clipboard_history_payload (
                    id TEXT PRIMARY KEY,
                    image_data BLOB,
                    snapshot_data BLOB NOT NULL,
                    file_urls_data BLOB NOT NULL,
                    FOREIGN KEY(id) REFERENCES clipboard_history_summary(id) ON DELETE CASCADE
                );
                """,
                nil,
                nil,
                nil
            )

            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS clipboard_history_summary_captured_at_idx ON clipboard_history_summary(captured_at DESC);", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS clipboard_history_summary_content_type_idx ON clipboard_history_summary(content_type);", nil, nil, nil)

            configureFTSIndexIfSupported(db: db)
            migrateLegacyJSONIfNeeded(db: db)
        }
    }

    private func configureFTSIndexIfSupported(db: OpaquePointer?) {
        let createFTS = """
        CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_history_fts USING fts5(
            id UNINDEXED,
            search_text,
            tokenize = 'trigram'
        );
        """
        guard sqlite3_exec(db, createFTS, nil, nil, nil) == SQLITE_OK else { return }

        sqlite3_exec(
            db,
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_history_summary_ai AFTER INSERT ON clipboard_history_summary BEGIN
                DELETE FROM clipboard_history_fts WHERE id = new.id;
                INSERT INTO clipboard_history_fts(id, search_text) VALUES (new.id, new.search_text);
            END;
            CREATE TRIGGER IF NOT EXISTS clipboard_history_summary_au AFTER UPDATE ON clipboard_history_summary BEGIN
                DELETE FROM clipboard_history_fts WHERE id = old.id;
                INSERT INTO clipboard_history_fts(id, search_text) VALUES (new.id, new.search_text);
            END;
            CREATE TRIGGER IF NOT EXISTS clipboard_history_summary_ad AFTER DELETE ON clipboard_history_summary BEGIN
                DELETE FROM clipboard_history_fts WHERE id = old.id;
            END;
            """,
            nil,
            nil,
            nil
        )

        if let checkStmt = prepareStatement(
            db,
            sql: "SELECT (SELECT COUNT(*) FROM clipboard_history_summary) != (SELECT COUNT(*) FROM clipboard_history_fts);"
        ) {
            defer { sqlite3_finalize(checkStmt) }
            if sqlite3_step(checkStmt) == SQLITE_ROW, sqlite3_column_int64(checkStmt, 0) != 0 {
                sqlite3_exec(db, "DELETE FROM clipboard_history_fts;", nil, nil, nil)
                sqlite3_exec(
                    db,
                    "INSERT INTO clipboard_history_fts(id, search_text) SELECT id, search_text FROM clipboard_history_summary;",
                    nil,
                    nil,
                    nil
                )
            }
        }
    }

    private func hasFTSTable(in db: OpaquePointer?) -> Bool {
        guard let stmt = prepareStatement(
            db,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'clipboard_history_fts' LIMIT 1;"
        ) else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func ftsTrigramQuery(for normalizedSearchText: String) -> String {
        let escaped = normalizedSearchText.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func likePattern(for normalizedSearchText: String) -> String {
        let escaped = normalizedSearchText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func migrateLegacyJSONIfNeeded(db: OpaquePointer?) {
        guard let db else { return }
        guard FileManager.default.fileExists(atPath: legacyFileURL.path) else { return }
        guard let statement = prepareStatement(db, sql: "SELECT COUNT(*) FROM clipboard_history_summary;") else { return }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return }
        let rowCount = Int(sqlite3_column_int64(statement, 0))
        guard rowCount == 0 else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: legacyFileURL),
              let entries = try? decoder.decode([ClipboardHistoryEntry].self, from: data) else {
            return
        }

        for entry in entries.sorted(by: { $0.capturedAt > $1.capturedAt }) {
            upsert(entry)
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer?) -> T?) -> T? {
        if let database {
            return body(database)
        }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            if opened != nil {
                sqlite3_close_v2(opened)
            }
            return nil
        }
        sqlite3_busy_timeout(opened, 3_000)
        database = opened
        return body(opened)
    }

    private func prepareStatement(_ db: OpaquePointer?, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private func existingID(forFingerprint fingerprint: String, in db: OpaquePointer?) -> UUID? {
        guard let statement = prepareStatement(
            db,
            sql: "SELECT id FROM clipboard_history_summary WHERE fingerprint = ? LIMIT 1;"
        ) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        bindText(fingerprint, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let idString = columnText(at: 0, in: statement) else {
            return nil
        }
        return UUID(uuidString: idString)
    }

    private func bindText(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, transientDestructor)
    }

    private func bindData(_ value: Data?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transientDestructor)
        }
    }

    private func columnText(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func columnData(at index: Int32, in statement: OpaquePointer?) -> Data? {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: byteCount)
    }

    private func searchText(for entry: ClipboardHistoryEntry) -> String {
        [entry.title, entry.subtitle, entry.plainText, entry.sourceAppName]
            .compactMap { $0?.lowercased() }
            .joined(separator: "\n")
    }

    private func encodeSnapshot(_ snapshot: PasteboardSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    private func decodeSnapshot(from data: Data) -> PasteboardSnapshot? {
        try? JSONDecoder().decode(PasteboardSnapshot.self, from: data)
    }

    private func encodeFileURLs(_ fileURLs: [URL]) -> Data? {
        try? JSONEncoder().encode(fileURLs)
    }

    private func decodeFileURLs(from data: Data) -> [URL]? {
        try? JSONDecoder().decode([URL].self, from: data)
    }

    private func lightweightSnapshot(
        contentType: ClipboardContentType,
        plainText: String?,
        imageData: Data?,
        snapshotData: Data?
    ) -> PasteboardSnapshot {
        switch contentType {
        case .text, .link:
            return PasteboardSnapshot.plainText(plainText ?? "")
        case .image:
            if let imageData {
                return PasteboardSnapshot.singleType(NSPasteboard.PasteboardType("org.webmproject.webp"), data: imageData)
            }
            return snapshotData.flatMap(decodeSnapshot(from:)) ?? PasteboardSnapshot(items: [])
        case .all, .file, .other:
            return snapshotData.flatMap(decodeSnapshot(from:)) ?? PasteboardSnapshot(items: [])
        }
    }

    private var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
