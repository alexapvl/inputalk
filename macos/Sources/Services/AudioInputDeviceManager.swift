import AudioToolbox
import CoreAudio
import Foundation
import Observation

extension Notification.Name {
    static let audioInputDevicesDidChange = Notification.Name(
        "Inputalk.audioInputDevicesDidChange")
}

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioInputSelection: Hashable, Sendable {
    case systemDefault
    case device(uid: String)
}

struct AudioInputFallbackNotice: Equatable, Sendable {
    let preferredName: String
    let fallbackName: String

    var message: String {
        "\(preferredName) is unavailable. Using \(fallbackName)."
    }

}

struct AudioInputResolution: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let deviceUID: String
    let name: String
    let fallbackNotice: AudioInputFallbackNotice?
}

protocol AudioInputDeviceProviding: AnyObject {
    func inputDevices() throws -> [AudioInputDevice]
    func defaultInputDeviceID() throws -> AudioDeviceID?
    func startObservingChanges() throws
    func stopObservingChanges()
}

final class CoreAudioInputDeviceProvider: AudioInputDeviceProviding {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    func inputDevices() throws -> [AudioInputDevice] {
        let deviceIDs = try deviceIDs()

        var seenUIDs = Set<String>()
        return deviceIDs.compactMap { deviceID in
            // Match macOS's selectable input list instead of exposing private or
            // app-owned virtual endpoints that merely publish an input stream.
            guard hasInputStreams(deviceID),
                isAlive(deviceID),
                canBeDefaultInputDevice(deviceID),
                let uid = try? stringProperty(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                ),
                let name = try? stringProperty(
                    objectID: deviceID,
                    selector: kAudioObjectPropertyName
                ),
                seenUIDs.insert(uid).inserted
            else { return nil }

            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func defaultInputDeviceID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(
                Self.systemObject,
                &address,
                0,
                nil,
                &dataSize,
                &deviceID
            )
        )
        return deviceID == kAudioObjectUnknown ? nil : deviceID
    }

    func startObservingChanges() throws {
        guard deviceListListener == nil, defaultInputListener == nil else { return }

        let postChange: AudioObjectPropertyListenerBlock = { _, _ in
            NotificationCenter.default.post(name: .audioInputDevicesDidChange, object: nil)
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(
            AudioObjectAddPropertyListenerBlock(
                Self.systemObject,
                &devicesAddress,
                .main,
                postChange
            )
        )
        deviceListListener = postChange

        let postDefaultChange: AudioObjectPropertyListenerBlock = { _, _ in
            NotificationCenter.default.post(name: .audioInputDevicesDidChange, object: nil)
        }
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            Self.systemObject,
            &defaultAddress,
            .main,
            postDefaultChange
        )
        if defaultStatus == noErr {
            defaultInputListener = postDefaultChange
        } else {
            stopObservingChanges()
            throw CoreAudioInputDeviceError(status: defaultStatus)
        }
    }

    func stopObservingChanges() {
        if let deviceListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                Self.systemObject,
                &address,
                .main,
                deviceListListener
            )
        }

        if let defaultInputListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                Self.systemObject,
                &address,
                .main,
                defaultInputListener
            )
        }

        deviceListListener = nil
        defaultInputListener = nil
    }

    deinit {
        stopObservingChanges()
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        return status == noErr && dataSize >= MemoryLayout<AudioStreamID>.size
    }

    private func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        uint32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive
        ) == 1
    }

    private func canBeDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        uint32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            scope: kAudioDevicePropertyScopeInput
        ) == 1
    }

    private func uint32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr ? value : nil
    }

    private func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                &value
            )
        )
        guard let value else { throw CoreAudioInputDeviceError.missingProperty }
        return value.takeRetainedValue() as String
    }

    private func deviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                Self.systemObject,
                &address,
                0,
                nil,
                &dataSize
            )
        )

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }

        var values = [AudioDeviceID](repeating: 0, count: count)
        try values.withUnsafeMutableBytes { buffer in
            var mutableSize = dataSize
            try check(
                AudioObjectGetPropertyData(
                    Self.systemObject,
                    &address,
                    0,
                    nil,
                    &mutableSize,
                    buffer.baseAddress!
                )
            )
        }
        return values
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CoreAudioInputDeviceError(status: status) }
    }
}

enum CoreAudioInputDeviceError: LocalizedError {
    case status(OSStatus)
    case missingProperty

    init(status: OSStatus) {
        self = .status(status)
    }

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return "CoreAudio returned error \(status)."
        case .missingProperty:
            return "CoreAudio returned an empty device property."
        }
    }
}

@MainActor
@Observable
final class AudioInputDeviceManager: NSObject {
    static let selectedDeviceUIDKey = "selectedInputDeviceUID"
    static let selectedDeviceNameKey = "selectedInputDeviceName"

    private(set) var devices: [AudioInputDevice] = []
    private(set) var defaultInputDeviceID: AudioDeviceID?
    private(set) var selection: AudioInputSelection
    private(set) var refreshError: String?
    private(set) var fallbackNotice: AudioInputFallbackNotice?

    @ObservationIgnored private let provider: AudioInputDeviceProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onDevicesChanged: (() -> Void)?

    init(
        provider: AudioInputDeviceProviding = CoreAudioInputDeviceProvider(),
        defaults: UserDefaults = .standard,
        observeChanges: Bool = true
    ) {
        self.provider = provider
        self.defaults = defaults
        if let uid = defaults.string(forKey: Self.selectedDeviceUIDKey) {
            selection = .device(uid: uid)
        } else {
            selection = .systemDefault
        }
        super.init()

        refresh()

        guard observeChanges else { return }
        do {
            try provider.startObservingChanges()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(audioInputDevicesDidChange),
                name: .audioInputDevicesDidChange,
                object: nil
            )
        } catch {
            refreshError = error.localizedDescription
        }
    }

    @objc private func audioInputDevicesDidChange() {
        refresh()
    }

    var defaultInputDevice: AudioInputDevice? {
        devices.first { $0.id == defaultInputDeviceID }
    }

    var selectedDevice: AudioInputDevice? {
        guard case .device(let uid) = selection else { return nil }
        return devices.first { $0.uid == uid }
    }

    var selectedDeviceName: String {
        switch selection {
        case .systemDefault:
            return defaultInputDevice.map { "System Default (\($0.name))" } ?? "System Default"
        case .device:
            return selectedDevice?.name
                ?? defaults.string(forKey: Self.selectedDeviceNameKey)
                ?? "Selected Microphone"
        }
    }

    var selectedDefaultLabel: String {
        defaultInputDevice.map { "System Default (\($0.name))" } ?? "System Default"
    }

    var unavailableSelectionMessage: String? {
        guard case .device = selection, selectedDevice == nil else { return nil }
        let fallbackName = fallbackDevice()?.name ?? "another available microphone"
        return "\(selectedDeviceName) is unavailable. Inputalk will use \(fallbackName)."
    }

    var fallbackDeviceName: String? {
        fallbackDevice()?.name
    }

    func select(_ selection: AudioInputSelection) {
        self.selection = selection
        fallbackNotice = nil

        switch selection {
        case .systemDefault:
            defaults.removeObject(forKey: Self.selectedDeviceUIDKey)
            defaults.removeObject(forKey: Self.selectedDeviceNameKey)
        case .device(let uid):
            defaults.set(uid, forKey: Self.selectedDeviceUIDKey)
            if let name = devices.first(where: { $0.uid == uid })?.name {
                defaults.set(name, forKey: Self.selectedDeviceNameKey)
            }
        }
    }

    func refresh() {
        do {
            let refreshedDevices = try provider.inputDevices()
            let refreshedDefault = try provider.defaultInputDeviceID()
            devices = refreshedDevices
            defaultInputDeviceID = refreshedDefault
            refreshError = nil
            defer { onDevicesChanged?() }

            guard case .device = selection else {
                fallbackNotice = nil
                return
            }

            if selectedDevice != nil {
                fallbackNotice = nil
            } else if let fallback = fallbackDevice() {
                let notice = AudioInputFallbackNotice(
                    preferredName: selectedDeviceName,
                    fallbackName: fallback.name
                )
                fallbackNotice = notice
            }
        } catch {
            refreshError = error.localizedDescription
        }
    }

    func resolutionForRecording() throws -> AudioInputResolution {
        refresh()

        switch selection {
        case .systemDefault:
            if let defaultInputDevice {
                return AudioInputResolution(
                    deviceID: defaultInputDevice.id,
                    deviceUID: defaultInputDevice.uid,
                    name: defaultInputDevice.name,
                    fallbackNotice: nil
                )
            }
            guard let firstDevice = devices.first else {
                throw AudioInputDeviceManagerError.noInputDevices
            }
            return AudioInputResolution(
                deviceID: firstDevice.id,
                deviceUID: firstDevice.uid,
                name: firstDevice.name,
                fallbackNotice: AudioInputFallbackNotice(
                    preferredName: "System Default",
                    fallbackName: firstDevice.name
                )
            )

        case .device:
            if let selectedDevice {
                return AudioInputResolution(
                    deviceID: selectedDevice.id,
                    deviceUID: selectedDevice.uid,
                    name: selectedDevice.name,
                    fallbackNotice: nil
                )
            }
            return try fallbackResolution(preferredName: selectedDeviceName)
        }
    }

    func fallbackResolution(
        preferredName: String,
        excludingUID: String? = nil
    ) throws -> AudioInputResolution {
        guard let fallback = fallbackDevice(excludingUID: excludingUID) else {
            throw AudioInputDeviceManagerError.noInputDevices
        }
        let notice = AudioInputFallbackNotice(
            preferredName: preferredName,
            fallbackName: fallback.name
        )
        fallbackNotice = notice
        return AudioInputResolution(
            deviceID: fallback.id,
            deviceUID: fallback.uid,
            name: fallback.name,
            fallbackNotice: notice
        )
    }

    private func fallbackDevice(excludingUID: String? = nil) -> AudioInputDevice? {
        let candidates = devices.filter { $0.uid != excludingUID }
        return candidates.first { $0.id == defaultInputDeviceID } ?? candidates.first
    }
}

enum AudioInputDeviceManagerError: LocalizedError {
    case noInputDevices

    var errorDescription: String? {
        "No microphone is available. Connect a microphone or choose an input in System Settings."
    }
}
