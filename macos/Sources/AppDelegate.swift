import AppKit
import QuartzCore
import SwiftUI

enum Defaults {
    static let showInDock = "showInDock"
}

// MARK: - App State

enum AppState {
    case idle
    case recording
    case processing
}

// MARK: - App Delegate (Menu Bar App)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let audioRecorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Defaults.showInDock: true])

        shortcutPreferences.onChange = { [weak self] in
            self?.hotkeyManager.reloadConfiguration()
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
        do {
            try audioRecorder.startRecording()
            appState = .recording
            updateMenuBarIcon(state: .recording)
            spectrumSmoother.reset()
            indicatorModel.spectrumLevels = AudioSpectrum.silence
            showIndicator(state: .recording)
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard audioRecorder.isRecording else { return }

        let samples = audioRecorder.stopRecording()
        appState = .processing
        updateMenuBarIcon(state: .processing)

        guard samples.count >= AudioRecorder.minimumSamples else {
            appState = .idle
            updateMenuBarIcon(state: .idle)
            dismissIndicator()
            return
        }

        updateIndicator(state: .processing)

        Task {
            do {
                // transcribe() waits for the model if it's still loading —
                // the user just sees "Transcribing" a bit longer on first use
                let text = try await transcriptionService.transcribe(audioSamples: samples)
                if !text.isEmpty {
                    TextInserter.insertText(text)
                    updateIndicator(state: .done(text: text))
                    indicatorDismissTask = Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        dismissIndicator()
                    }
                } else {
                    dismissIndicator()
                }
            } catch {
                print("Transcription failed: \(error)")
                dismissIndicator()
            }

            appState = .idle
            updateMenuBarIcon(state: .idle)
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
