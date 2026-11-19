import Foundation

/// 단일 오디오 프레임에서 추출한 음향 특징값
public struct AudioFrameFeatures: Sendable, Equatable {
    public let rmsDB: Double
    public let zeroCrossingRate: Double
    public let spectralFlux: Double
    public let estimatedPitchHz: Double

    public init(
        rmsDB: Double,
        zeroCrossingRate: Double,
        spectralFlux: Double,
        estimatedPitchHz: Double
    ) {
        self.rmsDB = rmsDB
        self.zeroCrossingRate = zeroCrossingRate
        self.spectralFlux = spectralFlux
        self.estimatedPitchHz = estimatedPitchHz
    }
}

/// PCM Float32 버퍼에서 음향 특징을 추출하는 순수 Swift DSP 분석기
public final class AudioFeatureExtractor {
    private var previousEnergy: Double = 0.0

    public init() {}

    public func reset() {
        previousEnergy = 0.0
    }

    public func extract(samples: [Float], sampleRate: Double) -> AudioFrameFeatures {
        guard !samples.isEmpty, sampleRate > 0 else {
            return AudioFrameFeatures(
                rmsDB: -90.0,
                zeroCrossingRate: 0.0,
                spectralFlux: 0.0,
                estimatedPitchHz: 0.0
            )
        }

        let count = Double(samples.count)
        var sumSquares: Double = 0.0
        var zeroCrossings = 0

        for index in samples.indices {
            let value = Double(samples[index])
            sumSquares += value * value
            if index > 0 {
                let prev = samples[index - 1]
                if (value >= 0 && prev < 0) || (value < 0 && prev >= 0) {
                    zeroCrossings += 1
                }
            }
        }

        let meanSquare = sumSquares / count
        let rms = sqrt(max(meanSquare, 1e-12))
        let rmsDB = max(-90.0, 20.0 * log10(rms))
        let zcr = Double(zeroCrossings) / max(1.0, count - 1.0)

        // 프레임 단위 에너지 급변량 (Spectral Flux 근사치)
        let currentEnergy = sqrt(sumSquares)
        let flux = max(0.0, currentEnergy - previousEnergy) / max(1.0, sqrt(count))
        previousEnergy = currentEnergy

        let pitchHz = rmsDB > -52.0 ? estimatePitchAutocorrelation(samples: samples, sampleRate: sampleRate) : 0.0

        return AudioFrameFeatures(
            rmsDB: rmsDB,
            zeroCrossingRate: zcr,
            spectralFlux: flux,
            estimatedPitchHz: pitchHz
        )
    }

    /// 자기상관(Autocorrelation) 기반 기본 주파수(F0) 추정 (사람 목소리 75Hz~450Hz 대역)
    private func estimatePitchAutocorrelation(samples: [Float], sampleRate: Double) -> Double {
        let minLag = max(1, Int(sampleRate / 450.0))
        let maxLag = min(samples.count / 2, Int(sampleRate / 75.0))
        guard maxLag > minLag else { return 0.0 }

        var zeroLagEnergy: Double = 0.0
        for sample in samples {
            let d = Double(sample)
            zeroLagEnergy += d * d
        }
        guard zeroLagEnergy > 1e-8 else { return 0.0 }

        var bestLag = 0
        var bestCorrelation = 0.0

        for lag in minLag...maxLag {
            var corr: Double = 0.0
            let limit = samples.count - lag
            for i in 0..<limit {
                corr += Double(samples[i]) * Double(samples[i + lag])
            }
            let normalized = corr / zeroLagEnergy
            if normalized > bestCorrelation {
                bestCorrelation = normalized
                bestLag = lag
            }
        }

        // 주기성이 충분할 때만 유효 피치로 인정 (잡음 배제)
        guard bestCorrelation >= 0.35, bestLag > 0 else { return 0.0 }
        return sampleRate / Double(bestLag)
    }
}
