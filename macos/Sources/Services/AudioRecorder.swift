import AVFoundation
import Foundation

/// Thread-safe audio sample collector used by the capture callback.
/// The capture queue is the analyzer's only writer. The lock protects samples and spectrum
/// snapshots read by the main thread while recording or stopping.
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

private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let collector: AudioSampleCollector

    init(collector: AudioSampleCollector) {
        self.collector = collector
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
            )
        else { return }

        let format = streamDescription.pointee
        guard format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32,
            format.mChannelsPerFrame == 1
        else { return }

        var bufferListSize = 0
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &bufferListSize,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: nil
            ) == noErr,
            bufferListSize >= MemoryLayout<AudioBufferList>.size
        else { return }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let bufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        var retainedBlockBuffer: CMBlockBuffer?
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: bufferList,
                bufferListSize: bufferListSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retainedBlockBuffer
            ) == noErr
        else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var samples: [Float] = []
        samples.reserveCapacity(
            buffers.reduce(0) { $0 + Int($1.mDataByteSize) / MemoryLayout<Float>.size }
        )

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self),
                    count: count
                )
            )
        }

        if !samples.isEmpty {
            collector.append(samples)
        }
    }
}

@MainActor
final class AudioRecorder {
    private static let sampleRate: Double = 16_000  // WhisperKit expects 16kHz mono

    private(set) var isRecording = false

    private let captureQueue = DispatchQueue(
        label: "Inputalk.AudioCapture",
        qos: .userInitiated
    )
    private var captureSession: AVCaptureSession?
    private var captureOutput: AVCaptureAudioDataOutput?
    private var captureDelegate: AudioCaptureDelegate?
    private let collector = AudioSampleCollector(sampleRate: Float(sampleRate))

    func startRecording(deviceUID: String) throws {
        guard !isRecording else { return }

        guard let device = Self.captureDevice(uid: deviceUID) else {
            throw AudioRecorderError.deviceUnavailable(deviceUID)
        }

        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioRecorderError.cannotOpenInput(device.localizedName)
        }
        let output = AVCaptureAudioDataOutput()
        let delegate = AudioCaptureDelegate(collector: collector)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AudioRecorderError.cannotAddInput(device.localizedName)
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioRecorderError.cannotAddOutput
        }
        session.addOutput(output)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        session.commitConfiguration()

        collector.reset()
        captureSession = session
        captureOutput = output
        captureDelegate = delegate

        session.startRunning()
        guard session.isRunning else {
            tearDownCapture()
            throw AudioRecorderError.captureFailed
        }
        isRecording = true
    }

    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        tearDownCapture()
        isRecording = false

        return collector.drain()
    }

    func currentSpectrumLevels() -> [Float] {
        collector.spectrumLevels()
    }

    /// Minimum number of samples for a valid recording (0.5s at 16kHz)
    static let minimumSamples = 8000

    static func duration(sampleCount: Int) -> TimeInterval {
        Double(sampleCount) / sampleRate
    }

    private static func captureDevice(uid: String) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.first { $0.uniqueID == uid }
    }

    private func tearDownCapture() {
        captureOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureSession?.stopRunning()
        captureQueue.sync {
            // Wait for already-enqueued sample callbacks before draining the collector.
        }
        captureSession = nil
        captureOutput = nil
        captureDelegate = nil
    }
}

enum AudioRecorderError: LocalizedError {
    case deviceUnavailable(String)
    case cannotOpenInput(String)
    case cannotAddInput(String)
    case cannotAddOutput
    case captureFailed

    var shouldTryFallback: Bool {
        switch self {
        case .deviceUnavailable, .cannotOpenInput, .cannotAddInput:
            return true
        case .cannotAddOutput, .captureFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "The selected microphone is unavailable."
        case .cannotOpenInput(let name):
            return "Inputalk could not open \(name)."
        case .cannotAddInput(let name):
            return "Inputalk could not use \(name) as an audio input."
        case .cannotAddOutput:
            return "Inputalk could not configure audio capture."
        case .captureFailed:
            return "The selected microphone could not start recording."
        }
    }
}
