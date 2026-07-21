import AVFoundation
import AudioToolbox
import Foundation

/// Thread-safe audio sample collector used by the real-time audio tap.
/// The audio tap is the analyzer's only writer. The lock protects samples and spectrum snapshots
/// read by the main thread while recording or stopping.
private final class AudioSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let spectrumAnalyzer: AudioSpectrumAnalyzer
    private var samples: ContiguousArray<Float> = []
    private var latestSpectrumLevels = AudioSpectrum.silence

    init(sampleRate: Float) {
        spectrumAnalyzer = AudioSpectrumAnalyzer(sampleRate: sampleRate)
    }

    func append(_ newSamples: [Float]) {
        let spectrumLevels = spectrumAnalyzer.analyze(newSamples)

        lock.lock()
        samples.append(contentsOf: newSamples)
        latestSpectrumLevels = spectrumLevels
        lock.unlock()
    }

    func spectrumLevels() -> [Float] {
        lock.lock()
        let result = latestSpectrumLevels
        lock.unlock()
        return result
    }

    func drain() -> [Float] {
        lock.lock()
        let result = Array(samples)
        samples.removeAll(keepingCapacity: true)
        latestSpectrumLevels = AudioSpectrum.silence
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        latestSpectrumLevels = AudioSpectrum.silence
        lock.unlock()
    }
}

@MainActor
final class AudioRecorder {
    private static let sampleRate: Double = 16_000  // WhisperKit expects 16kHz mono

    private(set) var isRecording = false

    private var audioEngine: AVAudioEngine?
    private let collector = AudioSampleCollector(sampleRate: Float(sampleRate))

    func startRecording(deviceID: AudioDeviceID? = nil) throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if let deviceID {
            try Self.route(inputNode, to: deviceID)
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw AudioRecorderError.formatError
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterError
        }

        collector.reset()

        Self.installAudioTap(
            on: inputNode,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            converter: converter,
            sampleRate: Self.sampleRate,
            collector: collector
        )

        try engine.start()
        audioEngine = engine
        isRecording = true
    }

    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        return collector.drain()
    }

    func currentSpectrumLevels() -> [Float] {
        collector.spectrumLevels()
    }

    /// Minimum number of samples for a valid recording (0.5s at 16kHz)
    static let minimumSamples = 8000

    nonisolated private static func route(
        _ inputNode: AVAudioInputNode,
        to deviceID: AudioDeviceID
    ) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioRecorderError.missingInputAudioUnit
        }

        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioRecorderError.deviceRoutingFailed(status)
        }
    }

    /// Installs the audio tap in a nonisolated context so the closure
    /// does not inherit @MainActor isolation (which would crash on the audio thread).
    nonisolated private static func installAudioTap(
        on inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        sampleRate: Double,
        collector: AudioSampleCollector
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            buffer, _ in

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0 else { return }

            guard
                let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) {
                _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil,
                let channelData = convertedBuffer.floatChannelData
            else { return }

            let samples = Array(
                UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(convertedBuffer.frameLength)
                ))

            collector.append(samples)
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case formatError
    case converterError
    case missingInputAudioUnit
    case deviceRoutingFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .formatError: return "Failed to create audio format"
        case .converterError: return "Failed to create audio converter"
        case .missingInputAudioUnit: return "Failed to access the microphone audio unit"
        case .deviceRoutingFailed(let status):
            return "Failed to select the microphone (CoreAudio error \(status))"
        }
    }
}
