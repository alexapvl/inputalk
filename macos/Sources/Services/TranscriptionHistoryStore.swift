import AppKit
import Foundation

struct TranscriptionHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let text: String
}

@MainActor
@Observable
final class TranscriptionHistoryStore {
    static let maxEntries = 100

    private(set) var entries: [TranscriptionHistoryEntry] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.inputalk.app"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    init(fileURL: URL = TranscriptionHistoryStore.defaultFileURL) {
        self.fileURL = fileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    /// Saves every meaningful transcript, newest first, capped at `maxEntries`.
    func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            !TranscriptionPostProcessor.isBlankAudio(trimmed)
        else { return }

        let entry = TranscriptionHistoryEntry(
            id: UUID(),
            createdAt: Date(),
            text: trimmed
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    func remove(id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return }
        save()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        save()
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

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? decoder.decode([TranscriptionHistoryEntry].self, from: data)
        else {
            entries = []
            return
        }
        entries = Array(decoded.prefix(Self.maxEntries))
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
