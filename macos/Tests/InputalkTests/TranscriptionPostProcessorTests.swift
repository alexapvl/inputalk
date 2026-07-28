import XCTest
@testable import Inputalk

final class TranscriptionPostProcessorTests: XCTestCase {
    func testRemovesTrailingBlankAudioAfterSpeech() {
        XCTAssertEqual(
            TranscriptionPostProcessor.process(
                "Hello from Inputalk. [BLANK_AUDIO]",
                removeFillerWords: true
            ),
            "Hello from Inputalk."
        )
    }

    func testRemovesTrailingSilenceAfterSpeech() {
        XCTAssertEqual(
            TranscriptionPostProcessor.process(
                "Ship the change. [silence] (Silence)",
                removeFillerWords: false
            ),
            "Ship the change."
        )
    }

    func testRecognizesBlankAudioOutput() {
        XCTAssertTrue(TranscriptionPostProcessor.isBlankAudio("[BLANK_AUDIO]"))
        XCTAssertTrue(TranscriptionPostProcessor.isBlankAudio(" (blank audio) "))
        XCTAssertFalse(TranscriptionPostProcessor.isBlankAudio("blank audio"))
    }

    func testKeepsBlankAudioWhenItIsOnlyOutput() {
        XCTAssertEqual(
            TranscriptionPostProcessor.process(
                "[BLANK_AUDIO]",
                removeFillerWords: true
            ),
            "[BLANK_AUDIO]"
        )
    }
}
