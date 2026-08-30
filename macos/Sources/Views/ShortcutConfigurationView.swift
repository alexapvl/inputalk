import AppKit
import Observation
import SwiftUI

enum ShortcutModifierToggleResult: Equatable {
    case selected
    case deselected
    case rejected
}

@MainActor
@Observable
final class ShortcutEditorModel: Identifiable {
    let id = UUID()
    var configuration: ShortcutConfiguration

    init(configuration: ShortcutConfiguration) {
        self.configuration = configuration
    }

    var canSave: Bool {
        configuration.isValid
    }

    func toggle(_ modifier: ShortcutModifier) -> ShortcutModifierToggleResult {
        if configuration.modifiers.contains(modifier) {
            guard configuration.modifiers.count > 1 else {
                return .rejected
            }
            configuration.modifiers.remove(modifier)
            return .deselected
        } else {
            configuration.modifiers.insert(modifier)
            return .selected
        }
    }
}

struct ShortcutConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var editor: ShortcutEditorModel
    let onSave: (ShortcutConfiguration) -> Void
    @State private var rejectedModifier: ShortcutModifier?
    @State private var rejectionTrigger = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 24) {
                keyboardSection
                behaviorSection
                summarySection
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(24)
        }
        .frame(width: 640, height: 525)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording Shortcut")
                    .font(.headline)
                Text("Choose the physical keys and how they should trigger dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                onSave(editor.configuration)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!editor.canSave)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hotkey")
                .font(.headline)

            KeyboardKeyRow(spacing: 8) {
                modifierKey(.fn)
                modifierKey(.leftControl)
                modifierKey(.leftOption)
                modifierKey(.leftCommand)
                SpaceKeycap()
                modifierKey(.rightCommand)
                modifierKey(.rightOption)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.separator.opacity(0.65), lineWidth: 1)
            }

            Text("Every selected key must be pressed together.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Behavior")
                .font(.headline)

            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Toggle Recording")
                        Text("Start or stop hands-free recording with the selected chord.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("Toggle Recording", selection: $editor.configuration.tapBehavior) {
                        ForEach(ShortcutTapBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hold to Record")
                        Text("Keep every selected key held down, then release any key to stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("Hold to Record", isOn: $editor.configuration.holdEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14))
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(editor.configuration.chordSummary, systemImage: "keyboard")
                .font(.subheadline)
                .bold()

            Text(editor.configuration.behaviorSummary)
                .font(.caption)
                .foregroundStyle(
                    editor.canSave ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                )

            if editor.configuration.modifiers.contains(.fn) {
                Label(
                    "Using Fn reserves the Globe key while Inputalk is running, so its normal emoji action is unavailable.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: editor.configuration.modifiers.contains(.fn))
    }

    private func modifierKey(_ modifier: ShortcutModifier) -> some View {
        Button {
            let result = withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                editor.toggle(modifier)
            }

            switch result {
            case .selected:
                ShortcutSoundFeedback.shared.playSelection()
            case .deselected:
                ShortcutSoundFeedback.shared.playDeselection()
            case .rejected:
                rejectedModifier = modifier
                rejectionTrigger += 1
                ShortcutSoundFeedback.shared.playRejection()
            }
        } label: {
            ModifierKeycap(
                modifier: modifier,
                isSelected: editor.configuration.modifiers.contains(modifier)
            )
            .phaseAnimator(
                [CGFloat.zero, -5, 5, -4, 4, -2, 2, 0],
                trigger: rejectionTrigger
            ) { content, offset in
                content.offset(x: rejectedModifier == modifier ? offset : 0)
            } animation: { _ in
                .easeInOut(duration: 0.045)
            }
        }
        .buttonStyle(
            KeycapButtonStyle(isSelected: editor.configuration.modifiers.contains(modifier))
        )
        .accessibilityLabel(modifier.displayName)
        .accessibilityHint("Include or remove this key from the recording shortcut")
    }
}

@MainActor
private final class ShortcutSoundFeedback {
    static let shared = ShortcutSoundFeedback()

    private let selectionSound = NSSound(named: NSSound.Name("Pop"))
    private let deselectionSound = NSSound(named: NSSound.Name("Tink"))

    func playSelection() {
        play(selectionSound)
    }

    func playDeselection() {
        play(deselectionSound)
    }

    func playRejection() {
        stopAll()
        NSSound.beep()
    }

    private func play(_ sound: NSSound?) {
        stopAll()
        guard let sound else { return }
        sound.currentTime = 0
        sound.play()
    }

    private func stopAll() {
        selectionSound?.stop()
        deselectionSound?.stop()
    }
}

private struct ModifierKeycap: View {
    let modifier: ShortcutModifier
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if modifier == .fn {
                    Image(systemName: modifier.symbol)
                        .imageScale(.medium)
                } else {
                    Text(modifier.symbol)
                }
            }
            .font(.title3)
            .foregroundStyle(isSelected ? .white : .secondary)

            Text(modifier.keyLabel)
                .font(.subheadline)
                .bold()
                .foregroundStyle(isSelected ? .white : .secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(10)
        .contentShape(.rect(cornerRadius: 12))
    }
}

private struct SpaceKeycap: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("space")
                .font(.subheadline)
                .bold()

            Text("Non-toggleable")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 68)
        .background(KeycapAppearance.inactiveBackground, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Space key")
        .accessibilityHint("Not selectable")
    }
}

private struct KeycapButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                isSelected
                    ? AnyShapeStyle(KeycapAppearance.selectedBackground)
                    : AnyShapeStyle(KeycapAppearance.inactiveBackground),
                in: .rect(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? AnyShapeStyle(.white.opacity(0.25))
                            : AnyShapeStyle(Color(nsColor: .separatorColor).opacity(0.75)),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: .black.opacity(configuration.isPressed ? 0.08 : 0.18),
                radius: configuration.isPressed ? 1 : 3,
                y: configuration.isPressed ? 1 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

private enum KeycapAppearance {
    static let inactiveBackground = Color.gray.opacity(0.12)
    static let selectedBackground = Color(red: 0.11, green: 0.12, blue: 0.14)
}

private struct KeyboardKeyRow: Layout {
    let spacing: CGFloat

    private let keyWeights: [CGFloat] = [1, 1, 1, 1.2, 2, 1.2, 1]

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = naturalSizes.map(\.width).reduce(0, +)
            + spacing * CGFloat(max(subviews.count - 1, 0))
        let height = naturalSizes.map(\.height).max() ?? 0

        return CGSize(width: proposal.width ?? naturalWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let totalSpacing = spacing * CGFloat(max(subviews.count - 1, 0))
        let availableWidth = max(bounds.width - totalSpacing, 0)
        let weights = subviews.indices.map { index in
            keyWeights.indices.contains(index) ? keyWeights[index] : 1
        }
        let totalWeight = weights.reduce(0, +)
        var x = bounds.minX

        for (index, subview) in subviews.enumerated() {
            let width = availableWidth * weights[index] / totalWeight
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }
}
