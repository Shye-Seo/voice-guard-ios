import Foundation

public struct RecordingSessionRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let fileName: String
    public let startedAt: Date
    public var endedAt: Date
    public var durationSeconds: TimeInterval
    public var peakAgitationScore: Double
    public var triggerReason: String
    public var note: String
    public var isStarred: Bool

    // MARK: - 오디오 분석 메타데이터 (v1.1에서 추가, 기존 index.json과 하위 호환)

    /// 녹음 구간 최대 음량(dB)
    public var peakRMSDB: Double
    /// 녹음 구간 평균 음량(dB)
    public var averageRMSDB: Double
    /// 녹음 구간 최대 추정 피치(F0, Hz)
    public var maxPitchHz: Double
    /// 격양 구간으로 표시된 총 시간(초)
    public var agitatedSeconds: TimeInterval
    /// 격양 구간 타임라인
    public var agitationEvents: [AgitationEvent]
    /// 0.5초 버킷 음량 엔벨로프(dB)
    public var levelEnvelope: [Double]
    /// 엔벨로프 1칸의 시간(초)
    public var envelopeBucketSeconds: Double
    /// 온디바이스 전사·핵심 쟁점 요약(사용자가 리포트를 만들었을 때만 존재, v1.2에서 추가)
    public var episodeReport: EpisodeReport?

    public init(
        id: UUID = UUID(),
        fileName: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        peakAgitationScore: Double,
        triggerReason: String,
        note: String = "",
        isStarred: Bool = false,
        peakRMSDB: Double = -90.0,
        averageRMSDB: Double = -90.0,
        maxPitchHz: Double = 0.0,
        agitatedSeconds: TimeInterval = 0.0,
        agitationEvents: [AgitationEvent] = [],
        levelEnvelope: [Double] = [],
        envelopeBucketSeconds: Double = 0.5,
        episodeReport: EpisodeReport? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.peakAgitationScore = peakAgitationScore
        self.triggerReason = triggerReason
        self.note = note
        self.isStarred = isStarred
        self.peakRMSDB = peakRMSDB
        self.averageRMSDB = averageRMSDB
        self.maxPitchHz = maxPitchHz
        self.agitatedSeconds = agitatedSeconds
        self.agitationEvents = agitationEvents
        self.levelEnvelope = levelEnvelope
        self.envelopeBucketSeconds = max(0.1, envelopeBucketSeconds)
        self.episodeReport = episodeReport
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case startedAt
        case endedAt
        case durationSeconds
        case peakAgitationScore
        case triggerReason
        case note
        case isStarred
        case peakRMSDB
        case averageRMSDB
        case maxPitchHz
        case agitatedSeconds
        case agitationEvents
        case levelEnvelope
        case envelopeBucketSeconds
        case episodeReport
    }

    /// 이전 버전에서 저장된 index.json(신규 필드 없음)도 그대로 읽을 수 있게 디코딩한다.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        peakAgitationScore = try container.decode(Double.self, forKey: .peakAgitationScore)
        triggerReason = try container.decode(String.self, forKey: .triggerReason)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        peakRMSDB = try container.decodeIfPresent(Double.self, forKey: .peakRMSDB) ?? -90.0
        averageRMSDB = try container.decodeIfPresent(Double.self, forKey: .averageRMSDB) ?? -90.0
        maxPitchHz = try container.decodeIfPresent(Double.self, forKey: .maxPitchHz) ?? 0.0
        agitatedSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .agitatedSeconds) ?? 0.0
        agitationEvents = try container.decodeIfPresent([AgitationEvent].self, forKey: .agitationEvents) ?? []
        levelEnvelope = try container.decodeIfPresent([Double].self, forKey: .levelEnvelope) ?? []
        envelopeBucketSeconds = max(0.1, try container.decodeIfPresent(Double.self, forKey: .envelopeBucketSeconds) ?? 0.5)
        episodeReport = try container.decodeIfPresent(EpisodeReport.self, forKey: .episodeReport)
    }

    /// 레코드에 저장된 메타데이터로 분석 리포트를 구성한다.
    public var analysisSummary: SessionAnalysisSummary {
        SessionAnalysisSummary(
            peakRMSDB: peakRMSDB,
            averageRMSDB: averageRMSDB,
            maxPitchHz: maxPitchHz,
            peakAgitationScore: peakAgitationScore,
            agitatedSeconds: agitatedSeconds,
            events: agitationEvents,
            levelEnvelope: levelEnvelope,
            envelopeBucketSeconds: envelopeBucketSeconds
        )
    }

    /// 분석 메타데이터가 없는(구버전) 녹음인지
    public var hasAnalysisMetadata: Bool {
        !agitationEvents.isEmpty || peakRMSDB > -89.0 || maxPitchHz > 0
    }

    /// 전사·쟁점 요약이 저장된 녹음인지
    public var hasEpisodeReport: Bool {
        episodeReport != nil
    }
}

/// 앱과 공유 시트에서 쓰는 리포트 문자열 포매터
public enum SessionReportFormatter {
    /// "00:03.4" 형식의 mm:ss.d 타임스탬프
    public static func timestampText(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        let tenths = Int(((clamped - Double(totalSeconds)) * 10).rounded(.down))
        return String(format: "%02d:%02d.%d", minutes, secs, min(9, max(0, tenths)))
    }

    /// 격양 구간 1건 요약
    public static func eventText(_ event: AgitationEvent) -> String {
        var parts: [String] = []
        parts.append("\(timestampText(event.startedAtOffset)) ~ \(timestampText(event.endedAtOffset))")
        parts.append(String(format: "%.1f초", event.durationSeconds))
        parts.append("피크 \(Int(event.peakRMSDB.rounded()))dB")
        if event.peakPitchHz > 0 {
            parts.append("\(Int(event.peakPitchHz.rounded()))Hz")
        }
        parts.append("격양도 \(Int((event.peakScore * 100).rounded()))%")
        return parts.joined(separator: " · ")
    }

    /// 녹음 1건의 공유용 리포트 본문
    public static func reportText(
        record: RecordingSessionRecord,
        maximumEventLines: Int = 12
    ) -> String {
        var lines: [String] = []
        lines.append("[VoiceGuard 분석 리포트]")
        lines.append("녹음 시작: \(Self.dateText(record.startedAt))")
        lines.append(String(format: "길이: %.1f초", record.durationSeconds))
        lines.append("트리거: \(record.triggerReason)")
        lines.append("")
        lines.append("[음향 지표]")
        lines.append("피크 음량: \(Int(record.peakRMSDB.rounded()))dB")
        lines.append("평균 음량: \(Int(record.averageRMSDB.rounded()))dB")
        if record.maxPitchHz > 0 {
            lines.append("최대 피치: \(Int(record.maxPitchHz.rounded()))Hz")
        }
        lines.append("최고 격양도: \(Int((record.peakAgitationScore * 100).rounded()))%")
        lines.append(String(format: "격양 구간 합계: %.1f초 (%d회)", record.agitatedSeconds, record.agitationEvents.count))

        if !record.agitationEvents.isEmpty {
            lines.append("")
            lines.append("[격양 구간 타임라인]")
            for event in record.agitationEvents.prefix(maximumEventLines) {
                lines.append("· \(eventText(event))")
            }
            if record.agitationEvents.count > maximumEventLines {
                lines.append("· 외 \(record.agitationEvents.count - maximumEventLines)건")
            }
        }

        if let episode = record.episodeReport {
            lines.append("")
            lines.append("[전사·쟁점 요약]")
            lines.append(episode.summary.headline)
            if let keyClaim = episode.summary.keyClaim {
                lines.append(
                    "· \(timestampText(keyClaim.startedAtOffset)) 「\(keyClaim.text)」"
                )
            }
        }

        if !record.note.isEmpty {
            lines.append("")
            lines.append("[메모]")
            lines.append(record.note)
        }

        lines.append("")
        lines.append("모든 분석은 기기 내부(온디바이스)에서만 수행되었습니다.")
        return lines.joined(separator: "\n")
    }

    public static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter.string(from: date)
    }
}
