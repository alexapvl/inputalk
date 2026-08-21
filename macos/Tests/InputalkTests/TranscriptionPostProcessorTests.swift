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

    func testRemovesTrailingInaudibleAfterSpeech() {
        XCTAssertEqual(
            TranscriptionPostProcessor.process(
                "Hello from Inputalk. [INAUDIBLE]",
                removeFillerWords: false
            ),
            "Hello from Inputalk."
        )
    }

    func testRecognizesNonSpeechOnlyOutput() {
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("[BLANK_AUDIO]"))
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly(" (blank audio) "))
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("[INAUDIBLE]"))
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("[INAUDIBLE] [BLANK_AUDIO]"))
        XCTAssertFalse(TranscriptionPostProcessor.isNonSpeechOnly("blank audio"))
        XCTAssertFalse(TranscriptionPostProcessor.isNonSpeechOnly("hello [INAUDIBLE]"))
    }

    func testKeepsNonSpeechMarkerWhenItIsOnlyOutput() {
        XCTAssertEqual(
            TranscriptionPostProcessor.process(
                "[BLANK_AUDIO]",
                removeFillerWords: true
            ),
            "[BLANK_AUDIO]"
        )
        XCTAssertEqual(
            TranscriptionPostProcessor.process(
                "[INAUDIBLE]",
                removeFillerWords: true
            ),
            "[INAUDIBLE]"
        )
    }
}
