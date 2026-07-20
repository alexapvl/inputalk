import AppKit
import Carbon.HIToolbox

/// Monitors an exact chord of physical modifier keys and turns tap, double-tap,
/// and hold gestures into recording actions.
@MainActor
final class HotkeyManager {
    var onRecordStart: (() -> Void)?
    var onRecordStop: (() -> Void)?

    private let preferences: ShortcutPreferences
    private var stateMachine: ShortcutStateMachine
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdWorkItem: DispatchWorkItem?
    private var doubleTapWorkItem: DispatchWorkItem?
    private var exactChordWasPressed = false

    private var originalFnUsageType: Int?
    private var hadOriginalFnUsageType = false
    private var isOverridingFnBehavior = false

    private static let holdThreshold: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.4

    /// Physical modifier masks from IOLLEvent.h, including unsupported modifiers
    /// so an extra Shift or right Control invalidates an exact chord.
    private static let allPhysicalModifierMask: UInt64 =
        0x0080_0000  // Fn
        | 0x0000_0001  // Left Control
        | 0x0000_2000  // Right Control
        | 0x0000_0002  // Left Shift
        | 0x0000_0004  // Right Shift
        | 0x0000_0008  // Left Command
        | 0x0000_0010  // Right Command
        | 0x0000_0020  // Left Option
        | 0x0000_0040  // Right Option

    init(preferences: ShortcutPreferences) {
        self.preferences = preferences
        self.stateMachine = ShortcutStateMachine(configuration: preferences.configuration)
    }

    func start() {
        guard AXIsProcessTrusted() else { return }
        guard eventTap == nil else { return }
        stop(shouldStopRecording: false)

        stateMachine = ShortcutStateMachine(configuration: preferences.configuration)
        exactChordWasPressed = false

        if preferences.configuration.modifiers.contains(.fn) {
            disableSystemFnBehavior()
        }

        let eventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                // Accessibility already covers Inputalk's text insertion. The callback
                // returns every event unchanged, so this active tap never blocks input.
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyEventCallback,
                userInfo: userInfo
            )
        else {
            restoreSystemFnBehavior()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        stop(shouldStopRecording: false)
    }

    func reloadConfiguration() {
        apply(stateMachine.reset())
        stop(shouldStopRecording: false)
        start()
    }

    func cancelRecording() {
        apply(stateMachine.reset())
        exactChordWasPressed = false
    }

    fileprivate func handleEvent(type: CGEventType, keyCode: UInt16, flagsRawValue: UInt64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            exactChordWasPressed = false
            apply(stateMachine.cancelPendingGesture())
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        if type == .keyDown {
            apply(stateMachine.ordinaryKeyPressed())
            return
        }

        guard type == .flagsChanged else { return }

        let configuration = preferences.configuration
        let physicalFlags = flagsRawValue & Self.allPhysicalModifierMask
        let isExactChord = physicalFlags == configuration.deviceMask

        if !exactChordWasPressed, isExactChord {
            exactChordWasPressed = true
            apply(stateMachine.chordPressed())
            return
        }

        guard exactChordWasPressed, !isExactChord else {
            if !physicalFlags.isSubset(of: configuration.deviceMask) {
                apply(stateMachine.cancelPendingGesture())
            }
            return
        }

        exactChordWasPressed = false
        let changedKeyIsSelected = configuration.modifiers.contains { $0.keyCode == keyCode }
        if changedKeyIsSelected {
            apply(stateMachine.chordReleased())
        } else {
            apply(stateMachine.cancelPendingGesture())
        }
    }

    private func stop(shouldStopRecording: Bool) {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        exactChordWasPressed = false

        if shouldStopRecording {
            apply(stateMachine.reset())
        } else {
            cancelTimers()
        }
        restoreSystemFnBehavior()
    }

    private func apply(_ effects: [ShortcutEffect]) {
        for effect in effects {
            switch effect {
            case .scheduleHold:
                scheduleHoldThreshold()
            case .cancelHold:
                holdWorkItem?.cancel()
                holdWorkItem = nil
            case .scheduleDoubleTapTimeout:
                scheduleDoubleTapTimeout()
            case .cancelDoubleTapTimeout:
                doubleTapWorkItem?.cancel()
                doubleTapWorkItem = nil
            case .startRecording:
                onRecordStart?()
            case .stopRecording:
                onRecordStop?()
            }
        }
    }

    private func scheduleHoldThreshold() {
        holdWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.holdWorkItem = nil
            self.apply(self.stateMachine.holdThresholdElapsed())
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold, execute: workItem)
    }

    private func scheduleDoubleTapTimeout() {
        doubleTapWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.doubleTapWorkItem = nil
            self.apply(self.stateMachine.doubleTapWindowElapsed())
        }
        doubleTapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: workItem)
    }

    private func cancelTimers() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        doubleTapWorkItem?.cancel()
        doubleTapWorkItem = nil
    }

    private func disableSystemFnBehavior() {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else { return }
        hadOriginalFnUsageType = defaults.object(forKey: "AppleFnUsageType") != nil
        originalFnUsageType = defaults.object(forKey: "AppleFnUsageType") as? Int
        defaults.set(0, forKey: "AppleFnUsageType")
        isOverridingFnBehavior = true
    }

    private func restoreSystemFnBehavior() {
        guard isOverridingFnBehavior else { return }
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else { return }

        if hadOriginalFnUsageType, let originalFnUsageType {
            defaults.set(originalFnUsageType, forKey: "AppleFnUsageType")
        } else {
            defaults.removeObject(forKey: "AppleFnUsageType")
        }
        originalFnUsageType = nil
        hadOriginalFnUsageType = false
        isOverridingFnBehavior = false
    }
}

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flagsRawValue = event.flags.rawValue

    DispatchQueue.main.async {
        manager.handleEvent(type: type, keyCode: keyCode, flagsRawValue: flagsRawValue)
    }

    return Unmanaged.passUnretained(event)
}

private extension UInt64 {
    func isSubset(of other: UInt64) -> Bool {
        self & ~other == 0
    }
}
