import CoreAudio
import XCTest

@testable import Inputalk

@MainActor
final class AudioInputDeviceManagerTests: XCTestCase {
    private let builtIn = AudioInputDevice(
        id: 1,
        uid: "built-in",
        name: "MacBook Microphone"
    )
    private let usb = AudioInputDevice(
        id: 2,
        uid: "usb",
        name: "USB Microphone"
    )

    func testNewSelectionFollowsSystemDefault() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let provider = MockAudioInputDeviceProvider(
            devices: [builtIn, usb],
            defaultDeviceID: builtIn.id
        )
        let manager = AudioInputDeviceManager(
            provider: provider,
            defaults: defaults,
            observeChanges: false
        )

        let resolution = try manager.resolutionForRecording()

        XCTAssertEqual(manager.selection, .systemDefault)
        XCTAssertEqual(resolution.deviceID, builtIn.id)
        XCTAssertEqual(resolution.deviceUID, builtIn.uid)
        XCTAssertEqual(resolution.name, builtIn.name)
        XCTAssertNil(resolution.fallbackNotice)
    }

    func testSpecificDeviceSelectionPersistsByUID() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let provider = MockAudioInputDeviceProvider(
            devices: [builtIn, usb],
            defaultDeviceID: builtIn.id
        )
        let manager = AudioInputDeviceManager(
            provider: provider,
            defaults: defaults,
            observeChanges: false
        )
        manager.select(.device(uid: usb.uid))

        let reloaded = AudioInputDeviceManager(
            provider: provider,
            defaults: defaults,
            observeChanges: false
        )
        let resolution = try reloaded.resolutionForRecording()

        XCTAssertEqual(reloaded.selection, .device(uid: usb.uid))
        XCTAssertEqual(resolution.deviceID, usb.id)
        XCTAssertEqual(resolution.deviceUID, usb.uid)
        XCTAssertEqual(resolution.name, usb.name)
    }

    func testMissingPreferredDeviceFallsBackToSystemDefault() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(usb.uid, forKey: AudioInputDeviceManager.selectedDeviceUIDKey)
        defaults.set(usb.name, forKey: AudioInputDeviceManager.selectedDeviceNameKey)
        let provider = MockAudioInputDeviceProvider(
            devices: [builtIn],
            defaultDeviceID: builtIn.id
        )
        let manager = AudioInputDeviceManager(
            provider: provider,
            defaults: defaults,
            observeChanges: false
        )

        let resolution = try manager.resolutionForRecording()

        XCTAssertEqual(resolution.deviceUID, builtIn.uid)
        XCTAssertEqual(resolution.name, builtIn.name)
        XCTAssertEqual(
            resolution.fallbackNotice,
            AudioInputFallbackNotice(
                preferredName: usb.name,
                fallbackName: builtIn.name
            )
        )
        XCTAssertNotNil(manager.unavailableSelectionMessage)
    }

    func testMissingSystemDefaultUsesFirstAvailableInput() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let provider = MockAudioInputDeviceProvider(
            devices: [usb],
            defaultDeviceID: nil
        )
        let manager = AudioInputDeviceManager(
            provider: provider,
            defaults: defaults,
            observeChanges: false
        )

        let resolution = try manager.resolutionForRecording()

        XCTAssertEqual(resolution.deviceUID, usb.uid)
        XCTAssertEqual(resolution.name, usb.name)
        XCTAssertNotNil(resolution.fallbackNotice)
    }

    func testPreferredDeviceRestoresAfterReconnect() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(usb.uid, forKey: AudioInputDeviceManager.selectedDeviceUIDKey)
        defaults.set(usb.name, forKey: AudioInputDeviceManager.selectedDeviceNameKey)
        let provider = MockAudioInputDeviceProvider(
            devices: [builtIn],
            defaultDeviceID: builtIn.id
        )
        let manager = AudioInputDeviceManager(
            provider: provider,
            defaults: defaults,
            observeChanges: false
        )

        _ = try manager.resolutionForRecording()
        provider.devices = [builtIn, usb]
        manager.refresh()
        let restoredResolution = try manager.resolutionForRecording()

        XCTAssertEqual(manager.selection, .device(uid: usb.uid))
        XCTAssertEqual(restoredResolution.deviceUID, usb.uid)
        XCTAssertNil(restoredResolution.fallbackNotice)
    }

    func testRefreshNotifiesWhenAvailableDevicesChange() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let provider = MockAudioInputDeviceProvider(
            devices: [builtIn, usb],
            defaultDeviceID: builtIn.id
        )
        let manager = AudioInputDeviceManager(
            provider: provider,
            defaults: defaults,
            observeChanges: false
        )
        var changeCount = 0
        manager.onDevicesChanged = { changeCount += 1 }

        provider.devices = [builtIn]
        manager.refresh()

        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(manager.devices, [builtIn])
    }

    func testNoAvailableInputReturnsClearError() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let manager = AudioInputDeviceManager(
            provider: MockAudioInputDeviceProvider(devices: [], defaultDeviceID: nil),
            defaults: defaults,
            observeChanges: false
        )

        XCTAssertThrowsError(try manager.resolutionForRecording()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                AudioInputDeviceManagerError.noInputDevices.localizedDescription
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AudioInputDeviceManagerTests.\(UUID().uuidString)")!
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}

private final class MockAudioInputDeviceProvider: AudioInputDeviceProviding {
    var devices: [AudioInputDevice]
    var defaultDeviceID: AudioDeviceID?

    init(devices: [AudioInputDevice], defaultDeviceID: AudioDeviceID?) {
        self.devices = devices
        self.defaultDeviceID = defaultDeviceID
    }

    func inputDevices() throws -> [AudioInputDevice] {
        devices
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        defaultDeviceID
    }

    func startObservingChanges() throws {}
    func stopObservingChanges() {}
}
