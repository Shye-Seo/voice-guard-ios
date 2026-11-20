import Foundation

/// 녹음 중 감지된 격양 구간 1건. 모든 시각은 녹음 파일 시작(프리롤 포함) 기준 상대 초 단위다.
public struct AgitationEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var startedAtOffset: TimeInterval
    public var endedAtOffset: TimeInterval
    public var peakScore: Double
    public var peakRMSDB: Double
    public var peakPitchHz: Double
    public var frameCount: Int

    public init(
        id: UUID = UUID(),
        startedAtOffset: TimeInterval,
        endedAtOffset: TimeInterval,
        peakScore: Double,
        peakRMSDB: Double,
        peakPitchHz: Double,
        frameCount: Int = 1
    ) {
        self.id = id
        self.startedAtOffset = startedAtOffset
        self.endedAtOffset = max(startedAtOffset, endedAtOffset)
        self.peakScore = peakScore
        self.peakRMSDB = peakRMSDB
        self.peakPitchHz = peakPitchHz
        self.frameCount = max(1, frameCount)
    }

    public var durationSeconds: TimeInterval {
        max(0, endedAtOffset - startedAtOffset)
    }
}

/// 한 세션의 오디오 분석 리포트
public struct SessionAnalysisSummary: Codable, Equatable, Sendable {
    public var peakRMSDB: Double
    public var averageRMSDB: Double
    public var maxPitchHz: Double
    public var peakAgitationScore: Double
    public var agitatedSeconds: TimeInterval
    public var events: [AgitationEvent]
    /// 0.5초 버킷 단위 음량 엔벨로프(dB). 타임라인 그래프에 사용한다.
    public var levelEnvelope: [Double]
    public var envelopeBucketSeconds: Double

    public init(
        peakRMSDB: Double = -90.0,
        averageRMSDB: Double = -90.0,
        maxPitchHz: Double = 0.0,
        peakAgitationScore: Double = 0.0,
        agitatedSeconds: TimeInterval = 0.0,
        events: [AgitationEvent] = [],
        levelEnvelope: [Double] = [],
        envelopeBucketSeconds: Double = 0.5
    ) {
        self.peakRMSDB = peakRMSDB
        self.averageRMSDB = averageRMSDB
        self.maxPitchHz = maxPitchHz
        self.peakAgitationScore = peakAgitationScore
        self.agitatedSeconds = agitatedSeconds
        self.events = events
        self.levelEnvelope = levelEnvelope
        self.envelopeBucketSeconds = max(0.1, envelopeBucketSeconds)
    }

    public var hasEvents: Bool { !events.isEmpty }
}

/// 격양 구간 타임라인 누적기.
///
/// 프레임 단위 판정을 받아 `mergeGapSeconds` 이내의 진정 구간은 같은 이벤트로 병합하고,
/// 이벤트별 피크(격양도·음량·피치)를 기록한다.
public final class AgitationTimelineAccumulator {
    public private(set) var events: [AgitationEvent] = []
    public var mergeGapSeconds: TimeInterval
    public var extensionScoreRatio: Double

    private var openEventIndex: Int?

    public init(mergeGapSeconds: TimeInterval = 1.0, extensionScoreRatio: Double = 0.82) {
        self.mergeGapSeconds = max(0.0, mergeGapSeconds)
        self.extensionScoreRatio = min(1.0, max(0.0, extensionScoreRatio))
    }

    public func reset() {
        events = []
        openEventIndex = nil
    }

    /// 한 프레임을 타임라인에 반영한다.
    /// - Parameters:
    ///   - isAgitated: 격양 상태(감지기가 `recordingAgitated`로 판정한 프레임)
    ///   - continuesEvent: 격양도가 임계 근처로 유지되어 구간을 이어갈 프레임
    public func ingest(
        features: AudioFrameFeatures,
        score: Double,
        isAgitated: Bool,
        continuesEvent: Bool,
        offset: TimeInterval,
        frameDuration: TimeInterval = 0.05
    ) {
        let keepsEventAlive = isAgitated || continuesEvent

        if let index = openEventIndex {
            let gap = offset - events[index].endedAtOffset
            if keepsEventAlive && gap <= mergeGapSeconds {
                events[index].endedAtOffset = max(events[index].endedAtOffset, offset + frameDuration)
                events[index].peakScore = max(events[index].peakScore, score)
                events[index].peakRMSDB = max(events[index].peakRMSDB, features.rmsDB)
                events[index].peakPitchHz = max(events[index].peakPitchHz, features.estimatedPitchHz)
                events[index].frameCount += 1
                return
            }
            if gap > mergeGapSeconds {
                openEventIndex = nil
            }
        }

        if keepsEventAlive {
            let event = AgitationEvent(
                startedAtOffset: offset,
                endedAtOffset: offset + frameDuration,
                peakScore: score,
                peakRMSDB: features.rmsDB,
                peakPitchHz: features.estimatedPitchHz
            )
            events.append(event)
            openEventIndex = events.count - 1
        }
    }

    /// 열려 있는 이벤트를 닫고 확정된 목록을 돌려준다(원본은 유지).
    public func finalize(at offset: TimeInterval) -> [AgitationEvent] {
        if let index = openEventIndex {
            events[index].endedAtOffset = max(events[index].endedAtOffset, min(offset, events[index].startedAtOffset))
            openEventIndex = nil
        }
        return events
    }

    public var totalAgitatedSeconds: TimeInterval {
        events.reduce(0.0) { $0 + $1.durationSeconds }
    }
}

/// 녹음 세션 동안 프레임을 받아 피크 dB·최대 F0·격양 구간 메타데이터를 만든다.
public final class RecordingSessionAccumulator {
    public var timeline: AgitationTimelineAccumulator
    public var envelopeBucketSeconds: TimeInterval
    public var frameDuration: TimeInterval

    private var peakRMSDB: Double = -90.0
    private var rmsSum: Double = 0.0
    private var rmsFrameCount: Int = 0
    private var maxPitchHz: Double = 0.0
    private var peakScore: Double = 0.0

    private var envelope: [Double] = []
    private var envelopeBucketStart: TimeInterval = 0.0
    private var envelopeBucketPeak: Double = -90.0

    public init(
        mergeGapSeconds: TimeInterval = 1.0,
        extensionScoreRatio: Double = 0.82,
        envelopeBucketSeconds: TimeInterval = 0.5,
        frameDuration: TimeInterval = 0.05
    ) {
        self.timeline = AgitationTimelineAccumulator(
            mergeGapSeconds: mergeGapSeconds,
            extensionScoreRatio: extensionScoreRatio
        )
        self.envelopeBucketSeconds = max(0.1, envelopeBucketSeconds)
        self.frameDuration = max(0.01, frameDuration)
    }

    public var currentPeakRMSDB: Double { peakRMSDB }
    public var currentMaxPitchHz: Double { maxPitchHz }
    public var currentPeakScore: Double { peakScore }
    public var events: [AgitationEvent] { timeline.events }

    /// 감지기 판정과 특징값을 받아 누적한다. `offset`은 녹음 파일 시작 기준 상대 초.
    public func ingest(
        features: AudioFrameFeatures,
        decision: DetectionDecision,
        offset: TimeInterval
    ) {
        ingest(
            features: features,
            score: decision.agitationScore,
            isAgitated: decision.state == .recordingAgitated,
            offset: offset,
            threshold: decision.scoreThreshold
        )
    }

    /// 감지기 판정 없이 직접 누적할 때 사용한다(테스트·재분석 경로).
    public func ingest(
        features: AudioFrameFeatures,
        score: Double,
        isAgitated: Bool,
        offset: TimeInterval,
        threshold: Double
    ) {
        peakRMSDB = max(peakRMSDB, features.rmsDB)
        maxPitchHz = max(maxPitchHz, features.estimatedPitchHz)
        peakScore = max(peakScore, score)
        rmsSum += features.rmsDB
        rmsFrameCount += 1

        timeline.ingest(
            features: features,
            score: score,
            isAgitated: isAgitated,
            continuesEvent: score >= threshold * timeline.extensionScoreRatio,
            offset: offset,
            frameDuration: frameDuration
        )

        appendToEnvelope(rmsDB: features.rmsDB, offset: offset)
    }

    public func finalize(at offset: TimeInterval) -> SessionAnalysisSummary {
        flushEnvelope(at: offset)
        let events = timeline.finalize(at: offset)
        return SessionAnalysisSummary(
            peakRMSDB: peakRMSDB,
            averageRMSDB: rmsFrameCount > 0 ? rmsSum / Double(rmsFrameCount) : -90.0,
            maxPitchHz: maxPitchHz,
            peakAgitationScore: peakScore,
            agitatedSeconds: events.reduce(0.0) { $0 + $1.durationSeconds },
            events: events,
            levelEnvelope: envelope,
            envelopeBucketSeconds: envelopeBucketSeconds
        )
    }

    private func appendToEnvelope(rmsDB: Double, offset: TimeInterval) {
        while offset - envelopeBucketStart >= envelopeBucketSeconds {
            envelope.append(envelopeBucketPeak)
            envelopeBucketStart += envelopeBucketSeconds
            envelopeBucketPeak = -90.0
        }
        envelopeBucketPeak = max(envelopeBucketPeak, rmsDB)
    }

    private func flushEnvelope(at offset: TimeInterval) {
        _ = offset
        if envelopeBucketPeak > -90.0 {
            envelope.append(envelopeBucketPeak)
            envelopeBucketPeak = -90.0
        }
    }
}
