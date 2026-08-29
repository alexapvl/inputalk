import AppKit
import CoreAudio
import QuartzCore
import SwiftUI

enum Defaults {
    static let showInDock = "showInDock"
    static let pasteHistoryFromMenuBar = "pasteHistoryFromMenuBar"
    static let settingsPage = "settingsPage"
}

enum SettingsPage: String {
    case dictation
    case history
    case general
}

// MARK: - App State

enum AppState {
    case idle
    case recording
    case processing
}

// MARK: - App Delegate (Menu Bar App)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let audioRecorder = AudioRecorder()
    let audioInputDevices = AudioInputDeviceManager()
    let transcriptionService = TranscriptionService()
    let transcriptionHistory = TranscriptionHistoryStore()
    let shortcutPreferences = ShortcutPreferences()
    lazy var hotkeyManager = HotkeyManager(preferences: shortcutPreferences)
    let permissions = PermissionManager.shared
    let updateService = UpdateService()

    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    private var appState: AppState = .idle

    /// Prevent App Nap from making the hotkey unresponsive
    private var activityToken: NSObjectProtocol?

    // MARK: - Floating Indicator

    private var indicatorPanel: NSPanel?
    private var indicatorHostingView: NSHostingView<FloatingIndicatorView>?
    private let indicatorModel = FloatingIndicatorModel()
    private var spectrumSmoother = SpectrumLevelSmoother()
    private var indicatorDismissTask: Task<Void, Never>?
    private var indicatorDisplayLink: CADisplayLink?
    private var lastIndicatorFrameTimestamp: CFTimeInterval?
    private var indicatorNeedsInitialFrame = false
    private var microphoneMenu: NSMenu?
    private var activeInputDeviceID: AudioDeviceID?
    private var activeInputDeviceName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            Defaults.showInDock: true,
            Defaults.pasteHistoryFromMenuBar: true,
        ])

        shortcutPreferences.onChange = { [weak self] in
            self?.hotkeyManager.reloadConfiguration()
        }
        audioInputDevices.onDevicesChanged = { [weak self] in
            self?.handleAudioInputDevicesChanged()
        }

        setupMainMenu()
        setupMenuBar()
        setupHotkey()

        if UserDefaults.standard.bool(forKey: Defaults.showInDock) {
            NSApp.setActivationPolicy(.regular)
        }

        // Re-check permissions when app becomes active (user returns from System Settings)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.permissions.refresh()
                self?.setupHotkey()
            }
        }

        // Prevent App Nap
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Global hotkey monitoring"
        )

        // Check onboarding
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        }

        // Load model in background (recording is allowed even before it's ready)
        Task {
            await transcriptionService.loadModel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        if audioRecorder.isRecording {
            _ = audioRecorder.stopRecording()
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        dismissIndicator()
    }

    // MARK: - Hotkey Setup

    private func setupHotkey() {
        guard permissions.hasAccessibility else { return }

        hotkeyManager.onRecordStart = { [weak self] in
            self?.startRecording()
        }
        hotkeyManager.onRecordStop = { [weak self] in
            self?.stopRecordingAndTranscribe()
        }
        hotkeyManager.start()
    }

    // MARK: - Recording Flow

    private func startRecording() {
        indicatorModel.notice = nil

        do {
            var resolution = try audioInputDevices.resolutionForRecording()
            do {
                try audioRecorder.startRecording(deviceUID: resolution.deviceUID)
            } catch let error as AudioRecorderError where error.shouldTryFallback {
                resolution = try audioInputDevices.fallbackResolution(
                    preferredName: resolution.name)
                try audioRecorder.startRecording(deviceUID: resolution.deviceUID)
            }

            appState = .recording
            updateMenuBarIcon(state: .recording)
            spectrumSmoother.reset()
            indicatorModel.spectrumLevels = AudioSpectrum.silence
            showIndicator(state: .recording)
            indicatorModel.notice = resolution.fallbackNotice?.message
            activeInputDeviceID = resolution.deviceID
            activeInputDeviceName = resolution.name
        } catch {
            print("Failed to start recording: \(error)")
            showTransientWarning(error.localizedDescription)
        }
    }

    private func stopRecordingAndTranscribe() {
        guard audioRecorder.isRecording else { return }

        let samples = audioRecorder.stopRecording()
        activeInputDeviceID = nil
        activeInputDeviceName = nil
        appState = .processing
        updateMenuBarIcon(state: .processing)

        guard samples.count >= AudioRecorder.minimumSamples else {
            appState = .idle
            updateMenuBarIcon(state: .idle)
            if let notice = indicatorModel.notice {
                showTransientWarning(notice)
            } else {
                showNonSpeechWarning()
            }
            return
        }

        updateIndicator(state: .processing)

        Task {
            do {
                // transcribe() waits for the model if it's still loading —
                // the user just sees "Transcribing" a bit longer on first use
                let text = try await transcriptionService.transcribe(audioSamples: samples)
                if TranscriptionPostProcessor.isNonSpeechOnly(text) {
                    showNonSpeechWarning(text)
                } else {
                    transcriptionHistory.append(text)
                    TextInserter.insertText(text)
                    updateIndicator(state: .done(text: text))
                    let dismissalDelay = indicatorModel.notice == nil ? 1.5 : 4
                    indicatorDismissTask = Task {
                        try? await Task.sleep(for: .seconds(dismissalDelay))
                        dismissIndicator()
                    }
                }
            } catch {
                print("Transcription failed: \(error)")
                dismissIndicator()
            }

            appState = .idle
            updateMenuBarIcon(state: .idle)
        }
    }

    private func handleAudioInputDevicesChanged() {
        guard audioRecorder.isRecording,
            let activeInputDeviceID,
            !audioInputDevices.devices.contains(where: { $0.id == activeInputDeviceID })
        else { return }

        let disconnectedName = activeInputDeviceName ?? "Microphone"
        if let fallbackName = audioInputDevices.fallbackDeviceName {
            indicatorModel.notice =
                "\(disconnectedName) disconnected. Recording stopped. Next recording will use \(fallbackName)."
        } else {
            indicatorModel.notice =
                "\(disconnectedName) disconnected. Recording stopped. No fallback microphone is available."
        }
        stopRecordingAndTranscribe()
    }

    private func showNonSpeechWarning(
        _ text: String = TranscriptionPostProcessor.blankAudioMarker
    ) {
        updateIndicator(state: .warning(text: text))
        indicatorDismissTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            dismissIndicator()
        }
    }

    private func showTransientWarning(_ message: String) {
        indicatorModel.notice = nil
        showIndicator(state: .warning(text: message))
        indicatorDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            dismissIndicator()
        }
    }

    // MARK: - Floating Indicator

    private func showIndicator(state: IndicatorState) {
        indicatorDismissTask?.cancel()
        indicatorDismissTask = nil
        indicatorModel.state = state

        if indicatorPanel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true

            let hostingView = NSHostingView(rootView: FloatingIndicatorView(model: indicatorModel))
            hostingView.sizingOptions = .intrinsicContentSize
            panel.contentView = hostingView

            indicatorPanel = panel
            indicatorHostingView = hostingView
        }

        indicatorPanel?.alphaValue = 0
        indicatorNeedsInitialFrame = true
        positionIndicatorNearCursor()
        indicatorPanel?.orderFrontRegardless()
        startIndicatorTracking()
    }

    private func updateIndicator(state: IndicatorState) {
        indicatorModel.state = state
        if state != .recording {
            indicatorModel.spectrumLevels = AudioSpectrum.silence
        }
        positionIndicatorNearCursor()
    }

    private func dismissIndicator() {
        indicatorDismissTask?.cancel()
        indicatorDismissTask = nil
        indicatorDisplayLink?.invalidate()
        indicatorDisplayLink = nil
        lastIndicatorFrameTimestamp = nil
        indicatorPanel?.orderOut(nil)
        indicatorPanel?.contentView = nil
        indicatorHostingView = nil
        indicatorPanel = nil
        indicatorNeedsInitialFrame = false
        indicatorModel.notice = nil
    }

    private func startIndicatorTracking() {
        guard indicatorDisplayLink == nil, let panel = indicatorPanel else { return }

        let displayLink = panel.displayLink(
            target: self,
            selector: #selector(updateIndicatorFrame(_:))
        )
        displayLink.add(to: .main, forMode: .common)
        indicatorDisplayLink = displayLink
    }

    @objc private func updateIndicatorFrame(_ displayLink: CADisplayLink) {
        let deltaTime = lastIndicatorFrameTimestamp.map {
            displayLink.timestamp - $0
        } ?? displayLink.duration
        lastIndicatorFrameTimestamp = displayLink.timestamp

        if appState == .recording {
            indicatorModel.spectrumLevels = spectrumSmoother.update(
                targetLevels: audioRecorder.currentSpectrumLevels(),
                deltaTime: deltaTime
            )
        }

        positionIndicatorNearCursor()

        if indicatorNeedsInitialFrame {
            indicatorHostingView?.layoutSubtreeIfNeeded()
            indicatorPanel?.displayIfNeeded()
            indicatorPanel?.alphaValue = 1
            indicatorNeedsInitialFrame = false
        }
    }

    private func positionIndicatorNearCursor() {
        guard let panel = indicatorPanel,
            let hostingView = indicatorHostingView,
            let screen = screenContainingMouse()
        else { return }

        hostingView.layoutSubtreeIfNeeded()
        let contentSize = hostingView.fittingSize
        let origin = FloatingIndicatorPositioner.origin(
            cursor: NSEvent.mouseLocation,
            contentSize: contentSize,
            visibleFrame: screen.visibleFrame
        )
        let frame = NSRect(origin: origin, size: contentSize)

        guard panel.frame != frame else { return }

        panel.setFrame(frame, display: true)
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            NSMenuItem(
                title: "About Inputalk",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""))
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Hide Inputalk",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            NSMenuItem(
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Inputalk",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(
            NSMenuItem(
                title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(
            NSMenuItem(
                title: "Close",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"))
        windowMenu.addItem(
            NSMenuItem(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = menuBarImage(for: .idle)
            button.action = #selector(statusBarButtonClicked)
        }
    }

    func updateMenuBarIcon(state: AppState) {
        guard let button = statusItem.button else { return }
        button.image = menuBarImage(for: state)
        button.contentTintColor = nil
        button.toolTip = state == .recording ? "Inputalk is recording" : "Inputalk"
    }

    private func menuBarImage(for state: AppState) -> NSImage? {
        switch state {
        case .idle, .recording:
            // Custom waveform icon from SPM resource bundle
            if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
                let image = NSImage(contentsOf: url)
            {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
            // Fallback to SF Symbol
            let image = NSImage(
                systemSymbolName: "waveform", accessibilityDescription: "Inputalk")
            image?.isTemplate = true
            return image
        case .processing:
            let image = NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: "Transcribing")
            image?.isTemplate = true
            return image
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        showContextMenu()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let microphoneItem = NSMenuItem(
            title: "Microphone", action: nil, keyEquivalent: "")
        let microphoneMenu = NSMenu(title: "Microphone")
        microphoneMenu.delegate = self
        microphoneItem.submenu = microphoneMenu
        menu.addItem(microphoneItem)
        self.microphoneMenu = microphoneMenu
        rebuildMicrophoneMenu(microphoneMenu)

        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu(title: "History")
        rebuildHistoryMenu(historyMenu)
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...", action: #selector(showSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates...", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = updateService.isConfigured
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Inputalk", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
        self.microphoneMenu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === microphoneMenu else { return }
        audioInputDevices.refresh()
        rebuildMicrophoneMenu(menu)
    }

    private func rebuildMicrophoneMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let canChangeDevice = appState != .recording

        let systemDefaultItem = NSMenuItem(
            title: audioInputDevices.selectedDefaultLabel,
            action: #selector(selectMicrophoneFromMenu(_:)),
            keyEquivalent: ""
        )
        systemDefaultItem.target = self
        systemDefaultItem.state = audioInputDevices.selection == .systemDefault ? .on : .off
        systemDefaultItem.isEnabled = canChangeDevice
        menu.addItem(systemDefaultItem)
        menu.addItem(.separator())

        for device in audioInputDevices.devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectMicrophoneFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            item.state = audioInputDevices.selection == .device(uid: device.uid) ? .on : .off
            item.isEnabled = canChangeDevice
            menu.addItem(item)
        }

        if audioInputDevices.devices.isEmpty {
            let unavailableItem = NSMenuItem(
                title: "No microphones available", action: nil, keyEquivalent: "")
            unavailableItem.isEnabled = false
            menu.addItem(unavailableItem)
        } else if case .device(let uid) = audioInputDevices.selection,
            audioInputDevices.selectedDevice == nil
        {
            let unavailableItem = NSMenuItem(
                title: "\(audioInputDevices.selectedDeviceName) (Unavailable)",
                action: nil,
                keyEquivalent: ""
            )
            unavailableItem.state = .on
            unavailableItem.isEnabled = false
            unavailableItem.representedObject = uid
            menu.addItem(unavailableItem)
        }

        if audioInputDevices.unavailableSelectionMessage != nil,
            let fallbackName = audioInputDevices.fallbackDeviceName
        {
            menu.addItem(.separator())
            let statusItem = NSMenuItem(
                title: "Using \(fallbackName) as fallback",
                action: nil,
                keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        } else if appState == .recording {
            menu.addItem(.separator())
            let statusItem = NSMenuItem(
                title: "Stop recording before switching microphones",
                action: nil,
                keyEquivalent: ""
            )
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }
    }

    @objc private func selectMicrophoneFromMenu(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            audioInputDevices.select(.device(uid: uid))
        } else {
            audioInputDevices.select(.systemDefault)
        }
    }

    private func rebuildHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let recent = Array(transcriptionHistory.entries.prefix(5))
        guard !recent.isEmpty else {
            let emptyItem = NSMenuItem(
                title: "No transcripts yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for entry in recent {
            let item = NSMenuItem(
                title: TranscriptionHistoryStore.menuTitle(for: entry.text),
                action: #selector(copyHistoryFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            item.toolTip = entry.text
            menu.addItem(item)
        }
    }

    @objc private func copyHistoryFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
            let entry = transcriptionHistory.entries.first(where: { $0.id == id })
        else { return }

        transcriptionHistory.copyToPasteboard(entry)

        guard UserDefaults.standard.bool(forKey: Defaults.pasteHistoryFromMenuBar) else { return }
        TextInserter.insertText(entry.text)
    }

    // MARK: - Windows

    @objc private func showSettingsAction() {
        showSettings()
    }

    @objc private func checkForUpdatesAction() {
        updateService.checkForUpdates()
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.titlebarAppearsTransparent = true
            window.center()
            window.contentView = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(transcriptionService)
                    .environmentObject(permissions)
                    .environmentObject(updateService)
                    .environment(shortcutPreferences)
                    .environment(audioInputDevices)
                    .environment(transcriptionHistory)
            )
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }

        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to Inputalk"
            window.center()
            window.contentView = NSHostingView(
                rootView: OnboardingView(onComplete: { [weak self] in
                    self?.closeOnboarding()
                })
                .environmentObject(self.transcriptionService)
                .environmentObject(self.permissions)
            )
            window.isReleasedWhenClosed = false
            window.delegate = self
            onboardingWindow = window
        }

        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onboardingWindow?.orderOut(nil)
        onboardingWindow?.close()
        onboardingWindow = nil
        if !UserDefaults.standard.bool(forKey: Defaults.showInDock) {
            NSApp.setActivationPolicy(.accessory)
        }
        setupHotkey()
    }

    func applyDockVisibilityPreference() {
        let showInDock = UserDefaults.standard.bool(forKey: Defaults.showInDock)
        let activeWindow = NSApp.keyWindow
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        Task { @MainActor in
            activeWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }

        if UserDefaults.standard.bool(forKey: Defaults.showInDock) { return }

        let otherWindow: NSWindow? =
            (closedWindow === settingsWindow) ? onboardingWindow : settingsWindow
        if otherWindow?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
