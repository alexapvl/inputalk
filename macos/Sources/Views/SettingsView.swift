import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var transcription: TranscriptionService
    @EnvironmentObject var permissions: PermissionManager
    @EnvironmentObject var updates: UpdateService
    @Environment(ShortcutPreferences.self) private var shortcutPreferences
    @Environment(AudioInputDeviceManager.self) private var audioInputDevices
    @Environment(TranscriptionHistoryStore.self) private var transcriptionHistory

    @AppStorage("removeFillerWords") private var removeFillerWords = true
    @AppStorage(Defaults.showInDock) private var showInDock = true

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var shortcutEditor: ShortcutEditorModel?
    @State private var showsMicrophonePermissionError = false
    @State private var copiedEntryID: UUID?
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        Form {
            // Shortcut
            Section {
                Button {
                    shortcutEditor = ShortcutEditorModel(
                        configuration: shortcutPreferences.configuration)
                } label: {
                    HStack(spacing: 12) {
                        Label("Shortcut", systemImage: "keyboard")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(shortcutPreferences.configuration.chordSummary)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(shortcutPreferences.configuration.behaviorSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                Picker(selection: audioInputSelection) {
                    Text(audioInputDevices.selectedDefaultLabel)
                        .tag(AudioInputSelection.systemDefault)

                    Divider()

                    if case .device(let uid) = audioInputDevices.selection,
                        audioInputDevices.selectedDevice == nil
                    {
                        Text("\(audioInputDevices.selectedDeviceName) (Unavailable)")
                            .tag(AudioInputSelection.device(uid: uid))
                    }

                    ForEach(audioInputDevices.devices) { device in
                        Text(device.name)
                            .tag(AudioInputSelection.device(uid: device.uid))
                    }
                } label: {
                    Label("Microphone", systemImage: "mic")
                }

                if let message = audioInputDevices.unavailableSelectionMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let error = audioInputDevices.refreshError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Input")
            }

            // Model
            Section {
                Picker(selection: $transcription.selectedModel) {
                    Text("Tiny (~75 MB)").tag("tiny")
                    Text("Base (~142 MB)").tag("base")
                    Text("Small (~466 MB)").tag("small")
                    Text("Medium (~1.5 GB)").tag("medium")
                } label: {
                    Label("Model", systemImage: "cpu")
                }

                HStack {
                    Label("Status", systemImage: "circle.fill")
                        .foregroundStyle(modelStatusColor)
                    Spacer()
                    Text(modelStatusText)
                        .foregroundStyle(.secondary)
                    if case .error = transcription.modelState {
                        Button("Retry") {
                            Task { await transcription.loadModel() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .onChange(of: transcription.selectedModel) {
                    Task { await transcription.loadModel() }
                }
            } header: {
                Text("Transcription")
            }

            // Post-processing
            Section {
                Toggle(isOn: $removeFillerWords) {
                    Label("Remove filler words", systemImage: "text.badge.minus")
                }
            } header: {
                Text("Post-processing")
            }

            // History
            Section {
                if transcriptionHistory.entries.isEmpty {
                    Text("Transcripts you dictate will show up here so you can copy them later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transcriptionHistory.entries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.text)
                                    .font(.body)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                Text(entry.createdAt, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(copiedEntryID == entry.id ? "Copied" : "Copy") {
                                copyHistoryEntry(entry)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(copiedEntryID == entry.id)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete(perform: deleteHistoryEntries)

                    Button("Clear History", role: .destructive) {
                        transcriptionHistory.clear()
                        copiedEntryID = nil
                    }
                }
            } header: {
                Text("History")
            } footer: {
                if !transcriptionHistory.entries.isEmpty {
                    Text("Keeps the last \(TranscriptionHistoryStore.maxEntries) transcripts on this Mac.")
                }
            }

            // General
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Label("Launch at Login", systemImage: "arrow.right.circle")
                }
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }

                Toggle(isOn: $showInDock) {
                    Label("Show in Dock", systemImage: "dock.rectangle")
                }
                .onChange(of: showInDock) { _, _ in
                    (NSApp.delegate as? AppDelegate)?.applyDockVisibilityPreference()
                }
            } header: {
                Text("General")
            }

            // Updates
            Section {
                Button {
                    updates.checkForUpdates()
                } label: {
                    Label("Check for Updates...", systemImage: "arrow.down.circle")
                }
                .disabled(!updates.isConfigured)

                Toggle(isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.automaticallyChecksForUpdates = $0 }
                )) {
                    Label("Automatically check for updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updates.isConfigured)

                if !updates.isConfigured {
                    Text("Sparkle updates are not configured for this build.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Updates")
            }

            // Permissions
            Section {
                HStack {
                    Label("Microphone", systemImage: "mic")
                    Spacer()
                    if permissions.hasMicrophone {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant") {
                            requestMicrophonePermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Label("Accessibility", systemImage: "hand.raised")
                    Spacer()
                    if permissions.hasAccessibility {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant") {
                            permissions.requestAccessibility()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Permissions")
            }

            // Storage
            Section {
                HStack {
                    Label("Model data", systemImage: "internaldrive")
                    Spacer()
                    Text(transcription.modelsDiskUsage)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(TranscriptionService.modelsDirectory.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(
                            nil,
                            inFileViewerRootedAtPath: TranscriptionService.modelsDirectory.path
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } header: {
                Text("Storage")
            }

            // About
            Section {
                HStack {
                    Text("Inputalk")
                    Spacer()
                    Text("v0.1.0")
                        .foregroundStyle(.secondary)
                }
                Text("Free, local voice-to-text powered by WhisperKit.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 520)
        .onAppear {
            audioInputDevices.refresh()
        }
        .sheet(item: $shortcutEditor) { editor in
            ShortcutConfigurationView(editor: editor) { configuration in
                shortcutPreferences.apply(configuration)
            }
        }
        .alert(
            "Microphone Access Required",
            isPresented: $showsMicrophonePermissionError
        ) {
            Button("Close", role: .cancel) {}
            Button("Open Microphone Settings") {
                permissions.openMicrophoneSettings()
            }
        } message: {
            Text(
                "Inputalk could not access the microphone. Allow microphone access in System Settings, then return to Inputalk."
            )
        }
    }

    // MARK: - Helpers

    private func requestMicrophonePermission() {
        Task {
            if await !permissions.requestMicrophone() {
                showsMicrophonePermissionError = true
            }
        }
    }

    private func copyHistoryEntry(_ entry: TranscriptionHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)

        copiedResetTask?.cancel()
        copiedEntryID = entry.id
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            if copiedEntryID == entry.id {
                copiedEntryID = nil
            }
        }
    }

    private func deleteHistoryEntries(at offsets: IndexSet) {
        let ids = offsets.map { transcriptionHistory.entries[$0].id }
        for id in ids {
            transcriptionHistory.remove(id: id)
        }
        if let copiedEntryID, ids.contains(copiedEntryID) {
            self.copiedEntryID = nil
        }
    }

    private var audioInputSelection: Binding<AudioInputSelection> {
        Binding(
            get: { audioInputDevices.selection },
            set: { audioInputDevices.select($0) }
        )
    }

    private var modelStatusColor: Color {
        switch transcription.modelState {
        case .ready: return .green
        case .loading, .downloading: return .orange
        case .error: return .red
        case .unloaded: return .gray
        }
    }

    private var modelStatusText: String {
        switch transcription.modelState {
        case .ready: return "Ready"
        case .loading: return "Loading..."
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .error(let msg): return msg
        case .unloaded: return "Not loaded"
        }
    }
}
