import XCTest
@testable import Inputalk

final class ModelLifecycleTests: XCTestCase {
    func testInstalledModelRequiresAllCompiledFiles() throws {
        let root = try makeTempModelsDirectory()
        XCTAssertTrue(ModelLifecycle.shouldDownload(variant: "small", modelsDirectory: root))
        XCTAssertFalse(ModelLifecycle.isInstalled(variant: "small", modelsDirectory: root))

        let folder = ModelLifecycle.modelFolder(for: "small", modelsDirectory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("MelSpectrogram.mlmodelc"))
        try Data().write(to: folder.appendingPathComponent("AudioEncoder.mlmodelc"))
        XCTAssertFalse(ModelLifecycle.isInstalled(variant: "small", modelsDirectory: root))

        try Data().write(to: folder.appendingPathComponent("TextDecoder.mlmodelc"))
        XCTAssertTrue(ModelLifecycle.isInstalled(variant: "small", modelsDirectory: root))
        XCTAssertFalse(ModelLifecycle.shouldDownload(variant: "small", modelsDirectory: root))
        XCTAssertTrue(ModelLifecycle.shouldDownload(variant: "base", modelsDirectory: root))
    }

    func testLatestRequestWins() {
        XCTAssertTrue(ModelLifecycle.shouldPublish(requestID: 2, latestRequestID: 2))
        XCTAssertFalse(ModelLifecycle.shouldPublish(requestID: 1, latestRequestID: 2))
        XCTAssertTrue(ModelLifecycle.shouldReuseLoadedModel(selected: "base", loaded: "base"))
        XCTAssertFalse(ModelLifecycle.shouldReuseLoadedModel(selected: "small", loaded: "base"))
        XCTAssertFalse(ModelLifecycle.shouldReuseLoadedModel(selected: "base", loaded: nil))
    }

    func testRecordingUsesLoadedModelWhileAnotherPrepares() {
        XCTAssertNil(
            ModelLifecycle.recordingBlockMessage(selected: "small", loaded: "base")
        )
        XCTAssertEqual(
            ModelLifecycle.recordingPrepareNotice(
                selected: "small",
                loaded: "base",
                isPreparing: true
            ),
            "Preparing Small - using Base"
        )
        XCTAssertNil(
            ModelLifecycle.recordingPrepareNotice(
                selected: "small",
                loaded: "base",
                isPreparing: false
            )
        )
    }

    func testRecordingBlocksWhenNoModelIsLoaded() {
        XCTAssertEqual(
            ModelLifecycle.recordingBlockMessage(selected: "small", loaded: nil),
            "Small isn't ready yet."
        )
        XCTAssertNil(
            ModelLifecycle.recordingPrepareNotice(
                selected: "small",
                loaded: nil,
                isPreparing: true
            )
        )
    }

    private func makeTempModelsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inputalk-model-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
