import Accelerate
import Foundation

enum AudioSpectrum {
    static let bandCount = 6
    static let silence = [Float](repeating: 0, count: bandCount)
}

final class AudioSpectrumAnalyzer {
    private struct FrequencyBand {
        let lower: Float
        let upper: Float
        let gainDB: Float
    }

    private static let fftSize = 512
    private static let frequencyBands = [
        FrequencyBand(lower: 80, upper: 180, gainDB: 0),
        FrequencyBand(lower: 180, upper: 320, gainDB: 0),
        FrequencyBand(lower: 320, upper: 500, gainDB: 1),
        FrequencyBand(lower: 500, upper: 1_200, gainDB: 3),
        FrequencyBand(lower: 1_200, upper: 3_000, gainDB: 5),
        FrequencyBand(lower: 3_000, upper: 8_000, gainDB: 8),
    ]
    private static let silenceThresholdDB: Float = -52
    private static let minimumBandDB: Float = -62
    private static let maximumBandDB: Float = -20

    private let sampleRate: Float
    private let setup: vDSP_DFT_Setup
    private var window: [Float] = []
    private var inputReal = [Float](repeating: 0, count: fftSize)
    private var inputImaginary = [Float](repeating: 0, count: fftSize)
    private var outputReal = [Float](repeating: 0, count: fftSize)
    private var outputImaginary = [Float](repeating: 0, count: fftSize)

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)!
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    func analyze(_ samples: [Float]) -> [Float] {
        let sampleCount = min(samples.count, Self.fftSize)
        guard sampleCount > 1 else { return AudioSpectrum.silence }

        let recentSamples = samples.suffix(sampleCount)
        let meanSquare = recentSamples.reduce(Float(0)) { $0 + $1 * $1 } / Float(sampleCount)
        let rmsDB = 20 * log10(max(sqrt(meanSquare), 0.000_000_1))
        guard rmsDB >= Self.silenceThresholdDB else { return AudioSpectrum.silence }

        if window.count != sampleCount {
            window = vDSP.window(
                ofType: Float.self,
                usingSequence: .hanningDenormalized,
                count: sampleCount,
                isHalfWindow: false
            )
        }

        vDSP.clear(&inputReal)
        for (index, sample) in recentSamples.enumerated() {
            inputReal[index] = sample * window[index]
        }

        inputReal.withUnsafeBufferPointer { inputRealPointer in
            inputImaginary.withUnsafeBufferPointer { inputImaginaryPointer in
                outputReal.withUnsafeMutableBufferPointer { outputRealPointer in
                    outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryPointer in
                        vDSP_DFT_Execute(
                            setup,
                            inputRealPointer.baseAddress!,
                            inputImaginaryPointer.baseAddress!,
                            outputRealPointer.baseAddress!,
                            outputImaginaryPointer.baseAddress!
                        )
                    }
                }
            }
        }

        let frequencyResolution = sampleRate / Float(Self.fftSize)
        let amplitudeScale = 2 / max(window.reduce(0, +), 1)

        return Self.frequencyBands.map { band in
            let lowerBin = max(1, Int(ceil(band.lower / frequencyResolution)))
            let upperBin = min(Self.fftSize / 2, Int(floor(band.upper / frequencyResolution)))
            guard lowerBin <= upperBin else { return 0 }

            var power: Float = 0
            for bin in lowerBin...upperBin {
                power += outputReal[bin] * outputReal[bin]
                    + outputImaginary[bin] * outputImaginary[bin]
            }

            let binCount = Float(upperBin - lowerBin + 1)
            let magnitude = sqrt(power / binCount) * amplitudeScale
            let decibels = 20 * log10(max(magnitude, 0.000_000_1)) + band.gainDB
            return min(max(
                (decibels - Self.minimumBandDB)
                    / (Self.maximumBandDB - Self.minimumBandDB),
                0
            ), 1)
        }
    }
}

struct SpectrumLevelSmoother {
    private(set) var levels = AudioSpectrum.silence

    mutating func update(targetLevels: [Float], deltaTime: TimeInterval) -> [Float] {
        let frameDuration = Float(min(max(deltaTime, 1.0 / 240.0), 1.0 / 15.0))

        for index in levels.indices {
            let target = min(max(targetLevels[safe: index] ?? 0, 0), 1)
            let timeConstant: Float = target > levels[index] ? 0.025 : 0.14
            let response = 1 - exp(-frameDuration / timeConstant)
            levels[index] += (target - levels[index]) * response

            if target == 0, levels[index] < 0.01 {
                levels[index] = 0
            }
        }

        return levels
    }

    mutating func reset() {
        levels = AudioSpectrum.silence
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
