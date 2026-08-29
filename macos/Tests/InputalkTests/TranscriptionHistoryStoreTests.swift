import XCTest

@testable import Inputalk

@MainActor
final class TranscriptionHistoryStoreTests: XCTestCase {
    func testAppendIgnoresEmptyWhitespaceOrNonSpeechOnlyText() throws {
        let paths = temporaryStorePaths()
        defer { removeStorePaths(paths) }

        let store = TranscriptionHistoryStore(databaseURL: paths.database, jsonURL: paths.json)
        store.append("", duration: 1)
        store.append("   \n\t", duration: 1)
        store.append("[BLANK_AUDIO]", duration: 1)
        store.append("[INAUDIBLE]", duration: 1)
        store.append("(silence)", duration: 1)
        store.append("(claps)", duration: 1)
        store.append("(cars honking)", duration: 1)
        store.append("(claps), (laughter)", duration: 1)
        XCTAssertTrue(store.entries.isEmpty)

        store.append("hello [INAUDIBLE]", duration: 2)
        XCTAssertEqual(store.entries.map(\.text), ["hello [INAUDIBLE]"])
    }

    func testAppendStoresNewestFirstAndPersistsDuration() throws {
        let paths = temporaryStorePaths()
        defer { removeStorePaths(paths) }

        let store = TranscriptionHistoryStore(databaseURL: paths.database, jsonURL: paths.json)
        store.append("first", duration: 1.5)
        store.append("second", duration: 2.25)

        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])
        XCTAssertEqual(store.entries.map(\.durationSeconds), [2.25, 1.5])

        let reloaded = TranscriptionHistoryStore(databaseURL: paths.database, jsonURL: paths.json)
        XCTAssertEqual(reloaded.entries.map(\.text), ["second", "first"])
        XCTAssertEqual(reloaded.entries.map(\.durationSeconds), [2.25, 1.5])
        XCTAssertEqual(reloaded.entries.map(\.id), store.entries.map(\.id))
    }

    func testAppendDoesNotCapEntries() throws {
        let paths = temporaryStorePaths()
        defer { removeStorePaths(paths) }

        let store = TranscriptionHistoryStore(databaseURL: paths.database, jsonURL: paths.json)
        for index in 1...12 {
            store.append("entry \(index)", duration: 1)
        }

        XCTAssertEqual(store.entries.count, 12)
        XCTAssertEqual(store.entries.first?.text, "entry 12")
        XCTAssertEqual(store.entries.last?.text, "entry 1")
    }

    func testRemoveAndClear() throws {
        let paths = temporaryStorePaths()
        defer { removeStorePaths(paths) }

        let store = TranscriptionHistoryStore(databaseURL: paths.database, jsonURL: paths.json)
        store.append("keep", duration: 1)
        store.append("drop", duration: 1)
        let dropID = store.entries[0].id

        store.remove(id: dropID)
        XCTAssertEqual(store.entries.map(\.text), ["keep"])

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.stats)

        let reloaded = TranscriptionHistoryStore(databaseURL: paths.database, jsonURL: paths.json)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    func testImportsJSONThenDeletesItAndSkipsUntimedRowsInStats() throws {
        let paths = temporaryStorePaths()
        defer { removeStorePaths(paths) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = [
            LegacyHistoryFixture(id: UUID(), createdAt: Date(), text: "ten words in this old imported transcript row")
        ]
        try encoder.encode(legacy).write(to: paths.json)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.json.path))

        let store = TranscriptionHistoryStore(databaseURL: paths.database, jsonURL: paths.json)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.json.path))
        XCTAssertEqual(store.entries.map(\.text), ["ten words in this old imported transcript row"])
        XCTAssertNil(store.entries.first?.durationSeconds)
        XCTAssertNil(store.stats)

        store.refreshStatsIfNeeded()
        XCTAssertNil(store.stats)

        store.append("one two three four five six", duration: 60)
        XCTAssertNil(store.stats)
        store.refreshStatsIfNeeded()
        XCTAssertEqual(store.stats?.wordCount, 6)
        XCTAssertEqual(store.stats?.durationSeconds, 60)
        XCTAssertEqual(store.stats?.wordsPerMinute, 6)
    }

    func testPooledWordsPerMinuteIgnoresDirtyFlagUntilRefresh() throws {
        let paths = temporaryStorePaths()
        defer { removeStorePaths(paths) }

        let store = TranscriptionHistoryStore(databaseURL: paths.database, jsonURL: paths.json)
        store.append("one two three four five", duration: 30)
        store.append("six seven eight nine ten", duration: 30)
        XCTAssertNil(store.stats)

        store.refreshStatsIfNeeded()
        XCTAssertEqual(store.stats?.wordCount, 10)
        XCTAssertEqual(store.stats?.durationSeconds, 60)
        XCTAssertEqual(store.stats?.wordsPerMinute, 10)

        store.refreshStatsIfNeeded()
        XCTAssertEqual(store.stats?.wordCount, 10)
    }

    func testMenuTitleCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(
            TranscriptionHistoryStore.menuTitle(for: "hello\n  world", maxCharacters: 56),
            "hello world"
        )
        XCTAssertEqual(
            TranscriptionHistoryStore.menuTitle(
                for: String(repeating: "a", count: 60),
                maxCharacters: 20
            ),
            String(repeating: "a", count: 17) + "..."
        )
    }

    func testFormatDuration() {
        XCTAssertEqual(TranscriptionHistoryStore.formatDuration(8), "8s")
        XCTAssertEqual(TranscriptionHistoryStore.formatDuration(124), "2m 4s")
        XCTAssertEqual(TranscriptionHistoryStore.formatDuration(3600), "1h")
        XCTAssertEqual(TranscriptionHistoryStore.formatDuration(3665), "1h 1m")
    }

    private struct StorePaths {
        let directory: URL
        let database: URL
        let json: URL
    }

    private func temporaryStorePaths() -> StorePaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inputalk-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StorePaths(
            directory: directory,
            database: directory.appendingPathComponent("history.sqlite"),
            json: directory.appendingPathComponent("history.json")
        )
    }

    private func removeStorePaths(_ paths: StorePaths) {
        try? FileManager.default.removeItem(at: paths.directory)
    }
}

private struct LegacyHistoryFixture: Codable {
    let id: UUID
    let createdAt: Date
    let text: String
}
