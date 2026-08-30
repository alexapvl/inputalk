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

    func testRemovesLeadingMarkersAfterSpeech() {
        XCTAssertEqual(
            TranscriptionPostProcessor.process(
                "[BLANK_AUDIO] Hello from Inputalk. [INAUDIBLE]",
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
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("(claps)"))
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("(silence)"))
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("(cars honking)"))
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("(claps), (silence)"))
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("(claps)."))
        XCTAssertTrue(TranscriptionPostProcessor.isNonSpeechOnly("(laughter) (music)"))
        XCTAssertFalse(TranscriptionPostProcessor.isNonSpeechOnly("blank audio"))
        XCTAssertFalse(TranscriptionPostProcessor.isNonSpeechOnly("hello [INAUDIBLE]"))
        XCTAssertFalse(TranscriptionPostProcessor.isNonSpeechOnly("hello (claps)"))
        XCTAssertFalse(TranscriptionPostProcessor.isNonSpeechOnly("cars honking"))
    }

    func testMapsEmptyOutputToBlankAudio() {
        XCTAssertEqual(
            TranscriptionPostProcessor.process("", removeFillerWords: true),
            TranscriptionPostProcessor.blankAudioMarker
        )
        XCTAssertEqual(
            TranscriptionPostProcessor.process("   \n", removeFillerWords: false),
            TranscriptionPostProcessor.blankAudioMarker
        )
        XCTAssertEqual(
            TranscriptionPostProcessor.process("um", removeFillerWords: true),
            TranscriptionPostProcessor.blankAudioMarker
        )
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
