import Foundation

public enum SensitivityPreset: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low: return "낮음 (큰 고성 위주)"
        case .medium: return "보통 (권장)"
        case .high: return "높음 (예민한 언쟁도 감지)"
        }
    }

    /// 격양 판정 점수 임계치 (0.0 ~ 1.0)
    public var scoreThreshold: Double {
        switch self {
        case .low: return 0.72
        case .medium: return 0.58
        case .high: return 0.45
        }
    }

    /// 배경 소음 대비 최소 dB 상승폭
    public var requiredDeltaDB: Double {
        switch self {
        case .low: return 16.0
        case .medium: return 11.5
        case .high: return 8.0
        }
    }

    /// 트리거 확정까지 필요한 연속 초과 프레임 수 (약 50ms/프레임 기준)
    public var requiredConsecutiveFrames: Int {
        switch self {
        case .low: return 8     // ~0.40s
        case .medium: return 6  // ~0.30s
        case .high: return 4    // ~0.20s
        }
    }
}

public enum MonitorState: String, Codable, Sendable {
    case idle
    case monitoring
    case recordingAgitated
    case cooldown
}

public struct DetectionDecision: Sendable, Equatable {
    public let state: MonitorState
    public let agitationScore: Double
    public let noiseFloorDB: Double
    public let shouldStartRecording: Bool
    public let shouldStopRecording: Bool
    public let triggerReason: String?

    public init(
        state: MonitorState,
        agitationScore: Double,
        noiseFloorDB: Double,
        shouldStartRecording: Bool,
        shouldStopRecording: Bool,
        triggerReason: String?
    ) {
        self.state = state
        self.agitationScore = agitationScore
        self.noiseFloorDB = noiseFloorDB
        self.shouldStartRecording = shouldStartRecording
        self.shouldStopRecording = shouldStopRecording
        self.triggerReason = triggerReason
    }
}

/// 배경 소음 적응형 베이스라인 + 히스테리시스 기반 감정 격양 상태 머신
public final class AgitationDetector {
    public var sensitivity: SensitivityPreset
    public var cooldownDurationSeconds: TimeInterval

    private(set) public var state: MonitorState = .monitoring
    private(set) public var noiseFloorDB: Double = -55.0

    private var consecutiveTriggerFrames: Int = 0
    private var lastAgitatedTimestamp: TimeInterval = 0
    private var baselinePitchHz: Double = 155.0

    public init(
        sensitivity: SensitivityPreset = .medium,
        cooldownDurationSeconds: TimeInterval = 12.0
    ) {
        self.sensitivity = sensitivity
        self.cooldownDurationSeconds = cooldownDurationSeconds
    }

    public func reset() {
        state = .monitoring
        noiseFloorDB = -55.0
        consecutiveTriggerFrames = 0
        lastAgitatedTimestamp = 0
        baselinePitchHz = 155.0
    }

    public func process(features: AudioFrameFeatures, timestamp: TimeInterval) -> DetectionDecision {
        // 1) 대기 상태일 때만 배경 소음 베이스라인을 천천히 추적 (EMA)
        if state == .monitoring && features.rmsDB < noiseFloorDB + 10.0 {
            noiseFloorDB = (noiseFloorDB * 0.96) + (features.rmsDB * 0.04)
        }

        // 유효 발화 피치의 완만한 기준선 업데이트
        if features.estimatedPitchHz >= 80 && features.estimatedPitchHz <= 240 && state == .monitoring {
            baselinePitchHz = (baselinePitchHz * 0.95) + (features.estimatedPitchHz * 0.05)
        }

        // 2) 격양 특징 점수화 (음량 급등 + 피치 상승 + 에너지 급변 + 날카로운 ZCR)
        let deltaDB = max(0.0, features.rmsDB - noiseFloorDB)
        let loudnessComponent = min(1.0, deltaDB / max(1.0, sensitivity.requiredDeltaDB * 1.4))

        let pitchRatio = features.estimatedPitchHz > 0
            ? max(0.0, (features.estimatedPitchHz - baselinePitchHz) / max(60.0, baselinePitchHz * 0.65))
            : 0.0
        let pitchComponent = min(1.0, pitchRatio)

        let fluxComponent = min(1.0, features.spectralFlux / 0.14)
        let zcrComponent = min(1.0, max(0.0, (features.zeroCrossingRate - 0.06) / 0.18))

        let agitationScore = (loudnessComponent * 0.48)
            + (pitchComponent * 0.24)
            + (fluxComponent * 0.18)
            + (zcrComponent * 0.10)

        let isAboveThreshold = agitationScore >= sensitivity.scoreThreshold
            && deltaDB >= sensitivity.requiredDeltaDB

        var shouldStart = false
        var shouldStop = false
        var reason: String? = nil

        switch state {
        case .idle:
            state = .monitoring
            fallthrough

        case .monitoring:
            if isAboveThreshold {
                consecutiveTriggerFrames += 1
                if consecutiveTriggerFrames >= sensitivity.requiredConsecutiveFrames {
                    state = .recordingAgitated
                    lastAgitatedTimestamp = timestamp
                    shouldStart = true
                    reason = buildTriggerReason(deltaDB: deltaDB, pitchHz: features.estimatedPitchHz, score: agitationScore)
                }
            } else {
                consecutiveTriggerFrames = max(0, consecutiveTriggerFrames - 1)
            }

        case .recordingAgitated:
            if isAboveThreshold || agitationScore >= (sensitivity.scoreThreshold * 0.82) {
                lastAgitatedTimestamp = timestamp
            } else {
                state = .cooldown
            }

        case .cooldown:
            if isAboveThreshold {
                state = .recordingAgitated
                lastAgitatedTimestamp = timestamp
            } else if (timestamp - lastAgitatedTimestamp) >= cooldownDurationSeconds {
                state = .monitoring
                consecutiveTriggerFrames = 0
                shouldStop = true
            }
        }

        return DetectionDecision(
            state: state,
            agitationScore: agitationScore,
            noiseFloorDB: noiseFloorDB,
            shouldStartRecording: shouldStart,
            shouldStopRecording: shouldStop,
            triggerReason: reason
        )
    }

    private func buildTriggerReason(deltaDB: Double, pitchHz: Double, score: Double) -> String {
        let roundedDelta = Int(deltaDB.rounded())
        let roundedScore = Int((score * 100).rounded())
        if pitchHz >= baselinePitchHz * 1.25 {
            return "성량 +\(roundedDelta)dB · 고음 피치(\(Int(pitchHz))Hz) 급등 · 격양도 \(roundedScore)%"
        }
        return "성량 +\(roundedDelta)dB 급등 · 격양도 \(roundedScore)%"
    }
}
