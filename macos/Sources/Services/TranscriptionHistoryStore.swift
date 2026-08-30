import AppKit
import Foundation
import SQLite3

struct TranscriptionHistoryEntry: Identifiable, Equatable, Sendable {
    let id: Int64
    let createdAt: Date
    let text: String
    let durationSeconds: TimeInterval?
    let wordCount: Int
}

struct TranscriptionStats: Equatable, Sendable {
    var wordCount: Int
    var durationSeconds: Double

    var wordsPerMinute: Double? {
        guard durationSeconds > 0 else { return nil }
        return Double(wordCount) / (durationSeconds / 60)
    }
}

@MainActor
@Observable
final class TranscriptionHistoryStore {
    private(set) var entries: [TranscriptionHistoryEntry] = []
    private(set) var stats: TranscriptionStats?

    private let handle = SQLiteHandle()
    private var database: OpaquePointer? { handle.db }
    private let databaseURL: URL
    private var statsNeedRefresh = true

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.inputalk.app"
        return appSupport.appendingPathComponent(bundleID, isDirectory: true)
    }

    static var defaultDatabaseURL: URL {
        defaultDirectory.appendingPathComponent("history.sqlite", isDirectory: false)
    }

    init(databaseURL: URL = TranscriptionHistoryStore.defaultDatabaseURL) {
        self.databaseURL = databaseURL
        openDatabase()
        entries = loadEntries()
    }

    /// Saves every meaningful transcript, newest first.
    func append(_ text: String, duration: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            !TranscriptionPostProcessor.isNonSpeechOnly(trimmed)
        else { return }

        let words = Self.wordCount(in: trimmed)
        let storedDuration = duration > 0 ? duration : nil
        let createdAt = Date()
        guard
            let id = insert(
                createdAt: createdAt,
                text: trimmed,
                durationSeconds: storedDuration,
                wordCount: words
            )
        else { return }

        let entry = TranscriptionHistoryEntry(
            id: id,
            createdAt: createdAt,
            text: trimmed,
            durationSeconds: storedDuration,
            wordCount: words
        )
        entries.insert(entry, at: 0)
        statsNeedRefresh = true
    }

    func remove(id: Int64) {
        guard entries.contains(where: { $0.id == id }),
            execute("DELETE FROM transcripts WHERE id = \(id)")
        else { return }
        entries.removeAll { $0.id == id }
        statsNeedRefresh = true
        refreshStatsIfNeeded()
    }

    func clear() {
        guard !entries.isEmpty, execute("DELETE FROM transcripts") else { return }
        entries = []
        statsNeedRefresh = true
        stats = nil
        refreshStatsIfNeeded()
    }

    func refreshStatsIfNeeded() {
        guard statsNeedRefresh else { return }
        stats = fetchStats()
        statsNeedRefresh = false
    }

    func copyToPasteboard(_ entry: TranscriptionHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    /// Single-line title for menu items, truncated with `...` when too long.
    static func menuTitle(for text: String, maxCharacters: Int = 56) -> String {
        let singleLine = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > maxCharacters else { return singleLine }
        return String(singleLine.prefix(maxCharacters - 3)) + "..."
    }

    static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }
        return "\(secs)s"
    }

    // MARK: - SQLite

    private func openDatabase() {
        let directory = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return
        }
        handle.db = db
        sqlite3_busy_timeout(db, 1_000)
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA foreign_keys = ON")

        if userVersion() < 1 {
            execute(
                """
                CREATE TABLE IF NOT EXISTS transcripts (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  created_at TEXT NOT NULL,
                  transcript_text TEXT NOT NULL,
                  duration_seconds REAL,
                  word_count INTEGER NOT NULL
                )
                """
            )
            execute(
                "CREATE INDEX IF NOT EXISTS idx_transcripts_created_at ON transcripts(created_at DESC)"
            )
            setUserVersion(1)
        }
    }

    private func loadEntries() -> [TranscriptionHistoryEntry] {
        guard let database else { return [] }
        let sql = """
            SELECT id, created_at, transcript_text, duration_seconds, word_count
            FROM transcripts
            ORDER BY created_at DESC, id DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var loaded: [TranscriptionHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let createdAt = date(from: columnText(statement, 1)),
                let text = columnText(statement, 2)
            else { continue }
            let duration: TimeInterval? =
                sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 3)
            let words = Int(sqlite3_column_int64(statement, 4))
            loaded.append(
                TranscriptionHistoryEntry(
                    id: id,
                    createdAt: createdAt,
                    text: text,
                    durationSeconds: duration,
                    wordCount: words
                )
            )
        }
        return loaded
    }

    private func fetchStats() -> TranscriptionStats? {
        guard let database else { return nil }
        let sql = """
            SELECT SUM(word_count), SUM(duration_seconds)
            FROM transcripts
            WHERE duration_seconds IS NOT NULL
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 1) == SQLITE_NULL {
            return nil
        }
        let words = Int(sqlite3_column_int64(statement, 0))
        let duration = sqlite3_column_double(statement, 1)
        guard duration > 0 else { return nil }
        return TranscriptionStats(wordCount: words, durationSeconds: duration)
    }

    private func insert(
        createdAt: Date,
        text: String,
        durationSeconds: TimeInterval?,
        wordCount: Int
    ) -> Int64? {
        guard let database else { return nil }
        let sql = """
            INSERT INTO transcripts (created_at, transcript_text, duration_seconds, word_count)
            VALUES (?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, isoFormatter.string(from: createdAt))
        bindText(statement, 2, text)
        if let durationSeconds {
            sqlite3_bind_double(statement, 3, durationSeconds)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int64(statement, 4, Int64(wordCount))

        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(database)
    }

    private func rowCount() -> Int {
        guard let database else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM transcripts", -1, &statement, nil)
            == SQLITE_OK,
            let statement
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func userVersion() -> Int {
        guard let database else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func setUserVersion(_ version: Int) {
        execute("PRAGMA user_version = \(version)")
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let database else { return false }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return isoFormatter.date(from: value)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteHandle: @unchecked Sendable {
    var db: OpaquePointer?

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }
}
