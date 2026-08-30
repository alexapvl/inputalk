import Foundation
import Observation

enum ShortcutModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case fn
    case leftControl
    case leftOption
    case leftCommand
    case rightCommand
    case rightOption

    var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .leftControl: return "Left Control"
        case .leftOption: return "Left Option"
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .rightOption: return "Right Option"
        }
    }

    var keyLabel: String {
        switch self {
        case .fn: return "fn"
        case .leftControl: return "ctrl"
        case .leftOption, .rightOption: return "opt"
        case .leftCommand, .rightCommand: return "cmd"
        }
    }

    var symbol: String {
        switch self {
        case .fn: return "globe"
        case .leftControl: return "⌃"
        case .leftOption, .rightOption: return "⌥"
        case .leftCommand, .rightCommand: return "⌘"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .leftControl: return 59
        case .leftOption: return 58
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .rightOption: return 61
        }
    }

    /// Device-specific modifier masks from IOLLEvent.h. Unlike aggregate CGEvent flags,
    /// these distinguish the left and right versions of Command and Option.
    var deviceMask: UInt64 {
        switch self {
        case .fn: return 0x0080_0000
        case .leftControl: return 0x0000_0001
        case .leftOption: return 0x0000_0020
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .rightOption: return 0x0000_0040
        }
    }

    var sortOrder: Int {
        switch self {
        case .fn: return 0
        case .leftControl: return 1
        case .leftOption: return 2
        case .leftCommand: return 3
        case .rightCommand: return 4
        case .rightOption: return 5
        }
    }
}

enum ShortcutTapBehavior: String, Codable, CaseIterable, Sendable {
    case off
    case single
    case double

    var label: String {
        switch self {
        case .off: return "Off"
        case .single: return "One Tap"
        case .double: return "Double Tap"
        }
    }
}

struct ShortcutConfiguration: Codable, Equatable, Sendable {
    var modifiers: Set<ShortcutModifier>
    var tapBehavior: ShortcutTapBehavior
    var holdEnabled: Bool

    static let newInstallDefault = ShortcutConfiguration(
        modifiers: [.rightOption],
        tapBehavior: .single,
        holdEnabled: true
    )

    static let existingUserDefault = ShortcutConfiguration(
        modifiers: [.fn],
        tapBehavior: .double,
        holdEnabled: true
    )

    var isValid: Bool {
        !modifiers.isEmpty && (tapBehavior != .off || holdEnabled)
    }

    var orderedModifiers: [ShortcutModifier] {
        modifiers.sorted { $0.sortOrder < $1.sortOrder }
    }

    var chordSummary: String {
        orderedModifiers.map(\.displayName).joined(separator: " + ")
    }

    var behaviorSummary: String {
        switch (tapBehavior, holdEnabled) {
        case (.off, true): return "Hold to record"
        case (.single, false): return "One tap to toggle"
        case (.single, true): return "One tap to toggle or hold to record"
        case (.double, false): return "Double tap to toggle"
        case (.double, true): return "Double tap to toggle or hold to record"
        case (.off, false): return "Choose at least one trigger"
        }
    }

    var deviceMask: UInt64 {
        modifiers.reduce(0) { $0 | $1.deviceMask }
    }
}

@MainActor
@Observable
final class ShortcutPreferences {
    private enum Storage {
        static let configuration = "shortcutConfiguration"
        static let version = "shortcutConfigurationVersion"
        static let currentVersion = 1
        static let completedOnboarding = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults
    private(set) var configuration: ShortcutConfiguration
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Storage.configuration),
            let decoded = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
            decoded.isValid
        {
            configuration = decoded
        } else {
            let isExistingUser = defaults.bool(forKey: Storage.completedOnboarding)
            configuration = isExistingUser ? .existingUserDefault : .newInstallDefault
            persist()
        }

        defaults.set(Storage.currentVersion, forKey: Storage.version)
    }

    func apply(_ configuration: ShortcutConfiguration) {
        guard configuration.isValid, configuration != self.configuration else { return }
        self.configuration = configuration
        persist()
        onChange?()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Storage.configuration)
    }
}

enum ShortcutEffect: Equatable {
    case scheduleHold
    case cancelHold
    case scheduleDoubleTapTimeout
    case cancelDoubleTapTimeout
    case startRecording
    case stopRecording
}

struct ShortcutStateMachine {
    private enum Phase: Equatable {
        case idle
        case chordPending
        case waitingForSecondTap
        case holdRecording
        case toggleRecording
        case stoppingToggle
    }

    private(set) var configuration: ShortcutConfiguration
    private var phase: Phase = .idle

    init(configuration: ShortcutConfiguration) {
        self.configuration = configuration
    }

    mutating func updateConfiguration(_ configuration: ShortcutConfiguration) -> [ShortcutEffect] {
        let effects = reset()
        self.configuration = configuration
        return effects
    }

    mutating func chordPressed() -> [ShortcutEffect] {
        switch phase {
        case .idle:
            phase = .chordPending
            return configuration.holdEnabled ? [.scheduleHold] : []

        case .waitingForSecondTap where configuration.tapBehavior == .double:
            phase = .toggleRecording
            return [.cancelDoubleTapTimeout, .startRecording]

        case .toggleRecording:
            phase = .stoppingToggle
            return [.stopRecording]

        case .chordPending, .waitingForSecondTap, .holdRecording, .stoppingToggle:
            return []
        }
    }

    mutating func chordReleased() -> [ShortcutEffect] {
        switch phase {
        case .chordPending:
            var effects: [ShortcutEffect] = configuration.holdEnabled ? [.cancelHold] : []
            switch configuration.tapBehavior {
            case .off:
                phase = .idle
            case .single:
                phase = .toggleRecording
                effects.append(.startRecording)
            case .double:
                phase = .waitingForSecondTap
                effects.append(.scheduleDoubleTapTimeout)
            }
            return effects

        case .holdRecording:
            phase = .idle
            return [.stopRecording]

        case .stoppingToggle:
            phase = .idle
            return []

        case .idle, .waitingForSecondTap, .toggleRecording:
            return []
        }
    }

    mutating func holdThresholdElapsed() -> [ShortcutEffect] {
        guard phase == .chordPending, configuration.holdEnabled else { return [] }
        phase = .holdRecording
        return [.startRecording]
    }

    mutating func doubleTapWindowElapsed() -> [ShortcutEffect] {
        guard phase == .waitingForSecondTap else { return [] }
        phase = .idle
        return []
    }

    mutating func ordinaryKeyPressed() -> [ShortcutEffect] {
        switch phase {
        case .chordPending:
            phase = .idle
            return configuration.holdEnabled ? [.cancelHold] : []
        case .waitingForSecondTap:
            phase = .idle
            return [.cancelDoubleTapTimeout]
        case .holdRecording:
            phase = .idle
            return [.stopRecording]
        case .idle, .toggleRecording, .stoppingToggle:
            return []
        }
    }

    mutating func cancelPendingGesture() -> [ShortcutEffect] {
        ordinaryKeyPressed()
    }

    mutating func reset() -> [ShortcutEffect] {
        var effects: [ShortcutEffect] = [.cancelHold, .cancelDoubleTapTimeout]
        if phase == .holdRecording || phase == .toggleRecording {
            effects.append(.stopRecording)
        }
        phase = .idle
        return effects
    }
}
