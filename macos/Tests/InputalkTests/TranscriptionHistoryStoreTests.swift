import XCTest

@testable import Inputalk

@MainActor
final class TranscriptionHistoryStoreTests: XCTestCase {
    func testAppendIgnoresEmptyOrWhitespaceText() throws {
        let fileURL = temporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = TranscriptionHistoryStore(fileURL: fileURL)
        store.append("")
        store.append("   \n\t")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testAppendStoresNewestFirstAndPersists() throws {
        let fileURL = temporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = TranscriptionHistoryStore(fileURL: fileURL)
        store.append("first")
        store.append("second")

        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])

        let reloaded = TranscriptionHistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.map(\.text), ["second", "first"])
    }

    func testAppendCapsAtMaxEntries() throws {
        let fileURL = temporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = TranscriptionHistoryStore(fileURL: fileURL)
        for index in 1...TranscriptionHistoryStore.maxEntries + 5 {
            store.append("entry \(index)")
        }

        XCTAssertEqual(store.entries.count, TranscriptionHistoryStore.maxEntries)
        XCTAssertEqual(
            store.entries.first?.text,
            "entry \(TranscriptionHistoryStore.maxEntries + 5)"
        )
        XCTAssertEqual(store.entries.last?.text, "entry 6")
    }

    func testRemoveAndClear() throws {
        let fileURL = temporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = TranscriptionHistoryStore(fileURL: fileURL)
        store.append("keep")
        store.append("drop")
        let dropID = store.entries[0].id

        store.remove(id: dropID)
        XCTAssertEqual(store.entries.map(\.text), ["keep"])

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)

        let reloaded = TranscriptionHistoryStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    private func temporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("inputalk-history-\(UUID().uuidString).json")
    }
}
