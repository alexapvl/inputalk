import XCTest
@testable import Inputalk

@MainActor
final class ShortcutConfigurationTests: XCTestCase {
    func testNewInstallDefaultsToRightOption() {
        let defaults = makeDefaults()
        defer { clear(defaults) }

        let preferences = ShortcutPreferences(defaults: defaults)

        XCTAssertEqual(preferences.configuration, .newInstallDefault)
        XCTAssertEqual(preferences.configuration.modifiers, [.rightOption])
        XCTAssertEqual(preferences.configuration.tapBehavior, .single)
        XCTAssertTrue(preferences.configuration.holdEnabled)
    }

    func testExistingUserMigratesToLegacyFnBehavior() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let preferences = ShortcutPreferences(defaults: defaults)

        XCTAssertEqual(preferences.configuration, .existingUserDefault)
        XCTAssertEqual(preferences.configuration.modifiers, [.fn])
        XCTAssertEqual(preferences.configuration.tapBehavior, .double)
        XCTAssertTrue(preferences.configuration.holdEnabled)
    }

    func testSavedConfigurationWinsOverMigrationDefaults() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let firstPreferences = ShortcutPreferences(defaults: defaults)
        let custom = ShortcutConfiguration(
            modifiers: [.leftControl, .leftOption],
            tapBehavior: .off,
            holdEnabled: true
        )
        firstPreferences.apply(custom)

        let reloadedPreferences = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(reloadedPreferences.configuration, custom)
    }

    func testSingleTapStartsAndNextPressStopsToggleRecording() {
        var stateMachine = ShortcutStateMachine(configuration: .newInstallDefault)

        XCTAssertEqual(stateMachine.chordPressed(), [.scheduleHold])
        XCTAssertEqual(stateMachine.chordReleased(), [.cancelHold, .startRecording])
        XCTAssertEqual(stateMachine.chordPressed(), [.stopRecording])
        XCTAssertEqual(stateMachine.chordReleased(), [])
    }

    func testDoubleTapStartsToggleRecording() {
        var stateMachine = ShortcutStateMachine(configuration: .existingUserDefault)

        XCTAssertEqual(stateMachine.chordPressed(), [.scheduleHold])
        XCTAssertEqual(
            stateMachine.chordReleased(),
            [.cancelHold, .scheduleDoubleTapTimeout]
        )
        XCTAssertEqual(
            stateMachine.chordPressed(),
            [.cancelDoubleTapTimeout, .startRecording]
        )
        XCTAssertEqual(stateMachine.chordReleased(), [])
    }

    func testHoldStartsAfterThresholdAndStopsOnRelease() {
        var stateMachine = ShortcutStateMachine(configuration: .newInstallDefault)

        XCTAssertEqual(stateMachine.chordPressed(), [.scheduleHold])
        XCTAssertEqual(stateMachine.holdThresholdElapsed(), [.startRecording])
        XCTAssertEqual(stateMachine.chordReleased(), [.stopRecording])
    }

    func testNormalKeyCancelsPendingTapOrHold() {
        var stateMachine = ShortcutStateMachine(configuration: .newInstallDefault)

        XCTAssertEqual(stateMachine.chordPressed(), [.scheduleHold])
        XCTAssertEqual(stateMachine.ordinaryKeyPressed(), [.cancelHold])
        XCTAssertEqual(stateMachine.chordReleased(), [])
    }

    func testNormalKeyStopsActiveHoldButNotToggleRecording() {
        var holdStateMachine = ShortcutStateMachine(configuration: .newInstallDefault)
        _ = holdStateMachine.chordPressed()
        _ = holdStateMachine.holdThresholdElapsed()
        XCTAssertEqual(holdStateMachine.ordinaryKeyPressed(), [.stopRecording])

        var toggleStateMachine = ShortcutStateMachine(configuration: .newInstallDefault)
        _ = toggleStateMachine.chordPressed()
        _ = toggleStateMachine.chordReleased()
        XCTAssertEqual(toggleStateMachine.ordinaryKeyPressed(), [])
    }

    func testChordMaskIncludesEverySelectedPhysicalKey() {
        let configuration = ShortcutConfiguration(
            modifiers: [.leftOption, .rightOption, .rightCommand],
            tapBehavior: .single,
            holdEnabled: false
        )

        XCTAssertEqual(
            configuration.deviceMask,
            ShortcutModifier.leftOption.deviceMask
                | ShortcutModifier.rightOption.deviceMask
                | ShortcutModifier.rightCommand.deviceMask
        )
    }

    func testShortcutEditorRejectsRemovingFinalModifier() {
        let editor = ShortcutEditorModel(configuration: .newInstallDefault)

        XCTAssertEqual(editor.toggle(.rightOption), .rejected)
        XCTAssertEqual(editor.configuration.modifiers, [.rightOption])

        XCTAssertEqual(editor.toggle(.leftControl), .selected)
        XCTAssertEqual(editor.toggle(.rightOption), .deselected)
        XCTAssertEqual(editor.configuration.modifiers, [.leftControl])
    }

    func testFloatingIndicatorAppearsBelowAndRightOfCursor() {
        let origin = FloatingIndicatorPositioner.origin(
            cursor: CGPoint(x: 400, y: 400),
            contentSize: CGSize(width: 100, height: 30),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(origin, CGPoint(x: 414, y: 356))
    }

    func testFloatingIndicatorFlipsAtBottomRightScreenEdge() {
        let origin = FloatingIndicatorPositioner.origin(
            cursor: CGPoint(x: 990, y: 5),
            contentSize: CGSize(width: 100, height: 30),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(origin, CGPoint(x: 876, y: 19))
    }

    func testSpectrumAnalyzerMapsTonesFromLowToHighBands() {
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 16_000)

        XCTAssertEqual(dominantBand(for: 125, analyzer: analyzer), 0)
        XCTAssertEqual(dominantBand(for: 250, analyzer: analyzer), 1)
        XCTAssertEqual(dominantBand(for: 420, analyzer: analyzer), 2)
        XCTAssertEqual(dominantBand(for: 700, analyzer: analyzer), 3)
        XCTAssertEqual(dominantBand(for: 2_000, analyzer: analyzer), 4)
        XCTAssertEqual(dominantBand(for: 6_000, analyzer: analyzer), 5)
    }

    func testSpectrumAnalyzerKeepsSilenceStill() {
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 16_000)

        XCTAssertEqual(
            analyzer.analyze([Float](repeating: 0, count: 512)),
            AudioSpectrum.silence
        )
    }

    func testSpectrumSmoothingIsRefreshRateIndependent() {
        var sixtyHertz = SpectrumLevelSmoother()
        var oneTwentyHertz = SpectrumLevelSmoother()
        let target = [Float](repeating: 1, count: AudioSpectrum.bandCount)

        for _ in 0..<60 {
            _ = sixtyHertz.update(targetLevels: target, deltaTime: 1.0 / 60.0)
        }
        for _ in 0..<120 {
            _ = oneTwentyHertz.update(targetLevels: target, deltaTime: 1.0 / 120.0)
        }

        for index in 0..<AudioSpectrum.bandCount {
            XCTAssertEqual(
                sixtyHertz.levels[index],
                oneTwentyHertz.levels[index],
                accuracy: 0.000_1
            )
        }
    }

    func testSpectrumSmoothingDoesNotInventMovementDuringSilence() {
        var smoother = SpectrumLevelSmoother()

        for _ in 0..<120 {
            _ = smoother.update(
                targetLevels: AudioSpectrum.silence,
                deltaTime: 1.0 / 120.0
            )
        }

        XCTAssertEqual(smoother.levels, AudioSpectrum.silence)
    }

    private func dominantBand(
        for frequency: Float,
        analyzer: AudioSpectrumAnalyzer
    ) -> Int? {
        let samples = (0..<512).map { index in
            Float(0.2 * sin(2 * .pi * Double(frequency) * Double(index) / 16_000))
        }
        let levels = analyzer.analyze(samples)
        return levels.indices.max { levels[$0] < levels[$1] }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ShortcutConfigurationTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}
