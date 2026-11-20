import Foundation

/// 1단계 에너지 게이트의 판정 상태
public enum EnergyGateState: String, Codable, Sendable {
    /// 배경 소음 수준 — 2단계(스펙트럴/피치) 분석을 건너뛴다
    case closed
    /// 에너지 상승 감지 — 매 프레임 2단계 분석을 수행한다
    case open
}

/// 2-Stage VAD 파이프라인 파라미터
public struct TwoStageVADConfiguration: Codable, Equatable, Sendable {
    /// 게이트가 열리는 배경 소음 대비 상승폭(dB)
    public var gateEnterMarginDB: Double
    /// 게이트가 닫히는 상승폭(dB) — 진입값보다 낮게 두어 히스테리시스를 만든다
    public var gateExitMarginDB: Double
    /// 게이트가 닫히기 전까지 유지할 프레임 수 (짧은 저음 구간에서 열림/닫힘 반복 방지)
    public var gateHoldFrames: Int
    /// 게이트가 닫힌 상태에서도 주기적으로 2단계 분석을 수행하는 간격(프레임)
    public var probeIntervalFrames: Int
    /// 1단계 RMS 계산 시 건너뛸 샘플 간격 (4 = 1/4 샘플만 연산)
    public var decimationFactor: Int
    /// 절대 하한선(dB) — 이보다 조용한 환경에서는 게이트를 열지 않는다
    public var absoluteFloorDB: Double
    /// 게이트가 닫힌 프레임에서 배경 소음을 추종하는 비율(EMA)
    public var noiseFloorAdaptationRate: Double

    public init(
        gateEnterMarginDB: Double = 9.0,
        gateExitMarginDB: Double = 6.0,
        gateHoldFrames: Int = 4,
        probeIntervalFrames: Int = 20,
        decimationFactor: Int = 4,
        absoluteFloorDB: Double = -62.0,
        noiseFloorAdaptationRate: Double = 0.04
    ) {
        self.gateEnterMarginDB = gateEnterMarginDB
        self.gateExitMarginDB = min(gateExitMarginDB, gateEnterMarginDB)
        self.gateHoldFrames = max(0, gateHoldFrames)
        self.probeIntervalFrames = max(1, probeIntervalFrames)
        self.decimationFactor = max(1, decimationFactor)
        self.absoluteFloorDB = absoluteFloorDB
        self.noiseFloorAdaptationRate = min(1.0, max(0.001, noiseFloorAdaptationRate))
    }

    /// 민감도 프리셋에 맞춘 권장 설정.
    ///
    /// 게이트 임계를 실제 트리거 임계(`requiredDeltaDB`)보다 2dB 낮게 두므로,
    /// 게이트가 닫힌 프레임은 `AgitationDetector`의 `deltaDB >= requiredDeltaDB` 조건을
    /// 통과할 수 없다. 즉 2단계 분석을 건너뛴 프레임에서 오탐이 생기지 않는다.
    public static func recommended(for sensitivity: SensitivityPreset) -> TwoStageVADConfiguration {
        let enter = max(4.0, sensitivity.requiredDeltaDB - 2.0)
        return TwoStageVADConfiguration(
            gateEnterMarginDB: enter,
            gateExitMarginDB: max(2.0, enter - 3.0)
        )
    }
}

/// 2-Stage VAD를 통과한 한 프레임의 분석 결과
public struct VADAnalysisFrame: Sendable, Equatable {
    /// 후속 판정에 쓰이는 특징값. 게이트가 닫힌 프레임은 피치/스펙트럴 성분이 0인 경량값이다.
    public let features: AudioFrameFeatures
    /// 1단계(플로우팅 서브샘플 RMS)에서 측정한 음량
    public let stageOneRMSDB: Double
    /// 이 프레임에서 2단계(FFT/자기상관 피치) 분석을 수행했는지
    public let didRunDeepAnalysis: Bool
    public let gateState: EnergyGateState
    public let timestamp: TimeInterval

    public init(
        features: AudioFrameFeatures,
        stageOneRMSDB: Double,
        didRunDeepAnalysis: Bool,
        gateState: EnergyGateState,
        timestamp: TimeInterval
    ) {
        self.features = features
        self.stageOneRMSDB = stageOneRMSDB
        self.didRunDeepAnalysis = didRunDeepAnalysis
        self.gateState = gateState
        self.timestamp = timestamp
    }
}

/// 2-Stage VAD 누적 통계 (배터리 절약 지표)
public struct TwoStageVADStats: Sendable, Equatable {
    public let totalFrames: Int
    public let deepAnalysisFrames: Int
    public let gateOpenFrames: Int
    /// 2단계 프레임 1회의 연산 비용을 1단계 프레임 대비 배수로 모델링한 값
    public let stageTwoCostMultiplier: Double

    public init(totalFrames: Int, deepAnalysisFrames: Int, gateOpenFrames: Int, stageTwoCostMultiplier: Double) {
        self.totalFrames = totalFrames
        self.deepAnalysisFrames = deepAnalysisFrames
        self.gateOpenFrames = gateOpenFrames
        self.stageTwoCostMultiplier = stageTwoCostMultiplier
    }

    public var gatedFrames: Int {
        max(0, totalFrames - deepAnalysisFrames)
    }

    /// 전체 프레임 중 2단계 분석을 수행한 비율
    public var deepAnalysisRatio: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(deepAnalysisFrames) / Double(totalFrames)
    }

    /// 게이트가 열려 있던 프레임 비율
    public var gateOpenRatio: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(gateOpenFrames) / Double(totalFrames)
    }

    /// 2단계 분석을 건너뛴 비율
    public var savedAnalysisRatio: Double {
        1.0 - deepAnalysisRatio
    }

    /// 모델링 기반 배터리 절약 추정치(%). 실측 전력량이 아니라 연산량 모델이다.
    public var estimatedBatterySavingsPercent: Double {
        guard totalFrames > 0 else { return 0 }
        let deep = Double(deepAnalysisFrames) * stageTwoCostMultiplier
        let light = Double(gatedFrames)
        let used = deep + light
        let baseline = Double(totalFrames) * stageTwoCostMultiplier
        guard baseline > 0 else { return 0 }
        return max(0.0, min(100.0, (1.0 - used / baseline) * 100.0))
    }
}

/// 2-Stage VAD 분석기.
///
/// 1단계: 샘플을 `decimationFactor`만큼 건너뛰며 RMS 에너지만 계산한다(프레임당 수백 연산).
/// 2단계: 게이트가 열린 프레임에서만 `AudioFeatureExtractor`로 ZCR/스펙트럴 플럭스/자기상관 F0를
///        계산한다(프레임당 수십만~백만 연산). 격양 판정은 1/10 이하의 프레임에서만 고비용 연산을 쓴다.
///
/// 스레드 안전: 내부 상태는 `NSLock`으로 보호되므로 오디오 탭 콜백과 메인 액터 어디서든 호출할 수 있다.
public final class TwoStageVADAnalyzer {
    /// 2단계 프레임 1회 비용 배수(보수적 모델).
    /// 48kHz/2048샘플 기준 자기상관은 75~450Hz 대역 534개 lag × 약 2048샘플 ≈ 109만 MAC인 반면,
    /// 1단계는 1/4 서브샘플 512개 RMS ≈ 1000 연산 수준이다. 실제 비율(≈1000배)보다 낮게 잡았다.
    public static let modeledStageTwoCostMultiplier: Double = 60.0

    private let lock = NSLock()
    private let extractor = AudioFeatureExtractor()
    private var configuration: TwoStageVADConfiguration
    private var noiseFloorDB: Double = -55.0
    private var hasPrimedNoiseFloor = false
    private var gateState: EnergyGateState = .closed
    private var holdFramesRemaining = 0
    private var framesSinceDeepAnalysis = 0
    private var totalFrames = 0
    private var deepFrames = 0
    private var openFrames = 0

    public init(configuration: TwoStageVADConfiguration = TwoStageVADConfiguration()) {
        self.configuration = configuration
    }

    public func update(configuration: TwoStageVADConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        self.configuration = configuration
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        extractor.reset()
        noiseFloorDB = -55.0
        hasPrimedNoiseFloor = false
        gateState = .closed
        holdFramesRemaining = 0
        framesSinceDeepAnalysis = 0
        totalFrames = 0
        deepFrames = 0
        openFrames = 0
    }

    public var stats: TwoStageVADStats {
        lock.lock()
        defer { lock.unlock() }
        return TwoStageVADStats(
            totalFrames: totalFrames,
            deepAnalysisFrames: deepFrames,
            gateOpenFrames: openFrames,
            stageTwoCostMultiplier: Self.modeledStageTwoCostMultiplier
        )
    }

    public var currentNoiseFloorDB: Double {
        lock.lock()
        defer { lock.unlock() }
        return noiseFloorDB
    }

    public var currentGateState: EnergyGateState {
        lock.lock()
        defer { lock.unlock() }
        return gateState
    }

    public func process(samples: [Float], sampleRate: Double, timestamp: TimeInterval) -> VADAnalysisFrame {
        lock.lock()
        defer { lock.unlock() }

        let config = configuration
        // 1단계는 decimationFactor로 건너뛰며 RMS만 계산한다(기본 1/4 샘플).
        let gateEnergyDB = Self.estimateEnergyDB(samples: samples, decimationFactor: config.decimationFactor)

        totalFrames += 1

        if !hasPrimedNoiseFloor {
            noiseFloorDB = gateEnergyDB
            hasPrimedNoiseFloor = true
        }

        let enterThreshold = max(noiseFloorDB + config.gateEnterMarginDB, config.absoluteFloorDB)
        let exitThreshold = max(noiseFloorDB + config.gateExitMarginDB, config.absoluteFloorDB - 6.0)

        switch gateState {
        case .closed:
            if gateEnergyDB >= enterThreshold {
                gateState = .open
                holdFramesRemaining = config.gateHoldFrames
            }
        case .open:
            if gateEnergyDB < exitThreshold {
                if holdFramesRemaining > 0 {
                    holdFramesRemaining -= 1
                } else {
                    gateState = .closed
                }
            } else {
                holdFramesRemaining = config.gateHoldFrames
            }
        }

        // 배경 소음은 게이트가 닫힌(= 평상시) 프레임에서만 추종한다.
        if gateState == .closed {
            noiseFloorDB += (gateEnergyDB - noiseFloorDB) * config.noiseFloorAdaptationRate
        }

        framesSinceDeepAnalysis += 1
        let isProbeFrame = gateState == .closed && framesSinceDeepAnalysis >= config.probeIntervalFrames
        let shouldRunDeepAnalysis = gateState == .open || isProbeFrame

        if gateState == .open {
            openFrames += 1
        }

        let features: AudioFrameFeatures
        if shouldRunDeepAnalysis {
            deepFrames += 1
            framesSinceDeepAnalysis = 0
            features = extractor.extract(samples: samples, sampleRate: sampleRate)
        } else {
            // 경량 프레임: 음량과 ZCR만 서브샘플로 추정하고 피치/스펙트럴 성분은 0으로 둔다.
            // 게이트가 닫힌 프레임은 트리거 임계(deltaDB)에 도달할 수 없으므로 오탐 위험이 없다.
            features = AudioFrameFeatures(
                rmsDB: gateEnergyDB,
                zeroCrossingRate: Self.estimateZeroCrossingRate(samples: samples, decimationFactor: config.decimationFactor),
                spectralFlux: 0.0,
                estimatedPitchHz: 0.0
            )
        }

        return VADAnalysisFrame(
            features: features,
            stageOneRMSDB: gateEnergyDB,
            didRunDeepAnalysis: shouldRunDeepAnalysis,
            gateState: gateState,
            timestamp: timestamp
        )
    }

    // MARK: - 1단계 저비용 추정

    /// 서브샘플 RMS → dB. `decimationFactor`가 1이면 전체 샘플을 사용한다.
    public static func estimateEnergyDB(samples: [Float], decimationFactor: Int = 1) -> Double {
        guard !samples.isEmpty else { return -90.0 }
        let stride = max(1, decimationFactor)
        var sumSquares: Double = 0
        var count = 0
        var index = 0
        while index < samples.count {
            let value = Double(samples[index])
            sumSquares += value * value
            count += 1
            index += stride
        }
        guard count > 0 else { return -90.0 }
        let rms = sqrt(max(sumSquares / Double(count), 1e-12))
        return max(-90.0, 20.0 * log10(rms))
    }

    /// 서브샘플 영교차율 추정 (0.0 ~ 1.0)
    public static func estimateZeroCrossingRate(samples: [Float], decimationFactor: Int = 1) -> Double {
        guard samples.count > 2 else { return 0.0 }
        let stride = max(1, decimationFactor)
        var previous: Float?
        var crossings = 0
        var compared = 0
        var index = 0
        while index < samples.count {
            let value = samples[index]
            if let prev = previous {
                if (value >= 0 && prev < 0) || (value < 0 && prev >= 0) {
                    crossings += 1
                }
                compared += 1
            }
            previous = value
            index += stride
        }
        guard compared > 0 else { return 0.0 }
        return Double(crossings) / Double(compared)
    }
}
