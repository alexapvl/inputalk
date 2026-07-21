import Observation
import SwiftUI

enum IndicatorState: Equatable {
    case recording
    case processing
    case done(text: String)
    case warning(text: String)
}

@MainActor
@Observable
final class FloatingIndicatorModel {
    var state: IndicatorState = .recording
    var spectrumLevels = AudioSpectrum.silence
    var notice: String?
}

struct FloatingIndicatorView: View {
    let model: FloatingIndicatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: model.notice == nil ? 0 : 5) {
            HStack(spacing: 8) {
                switch model.state {
                case .recording:
                    CursorWaveform(levels: model.spectrumLevels)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))

                case .processing:
                    ProgressView()
                        .controlSize(.small)

                    Text("Transcribing")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .transition(.move(edge: .trailing).combined(with: .opacity))

                case .done(let text):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))

                    Text(text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))

                case .warning(let text):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 16))

                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, model.state == .recording ? 10 : 14)
        .padding(.vertical, model.state == .recording ? 8 : 10)
        .modifier(GlassCapsuleModifier())
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: model.state)
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: model.notice)
    }
}

private struct CursorWaveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<AudioSpectrum.bandCount, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.pink, .orange],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 2.5, height: barHeight(at: index))
            }
        }
        .frame(width: 23, height: 14)
        .accessibilityLabel("Recording")
    }

    private func barHeight(at index: Int) -> CGFloat {
        let level = levels.indices.contains(index) ? levels[index] : 0
        return 2 + 12 * CGFloat(level)
    }
}

enum FloatingIndicatorPositioner {
    static func origin(
        cursor: CGPoint,
        contentSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 14,
        margin: CGFloat = 8
    ) -> CGPoint {
        var x = cursor.x + gap
        if x + contentSize.width > visibleFrame.maxX - margin {
            x = cursor.x - contentSize.width - gap
        }

        var y = cursor.y - contentSize.height - gap
        if y < visibleFrame.minY + margin {
            y = cursor.y + gap
        }

        let maximumX = max(visibleFrame.minX + margin, visibleFrame.maxX - contentSize.width - margin)
        let maximumY = max(visibleFrame.minY + margin, visibleFrame.maxY - contentSize.height - margin)

        return CGPoint(
            x: min(max(x, visibleFrame.minX + margin), maximumX),
            y: min(max(y, visibleFrame.minY + margin), maximumY)
        )
    }
}

// MARK: - Liquid Glass with fallback

private struct GlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(.blue.opacity(0.15)), in: .capsule)
        } else {
            content
                .background {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                }
        }
    }
}
