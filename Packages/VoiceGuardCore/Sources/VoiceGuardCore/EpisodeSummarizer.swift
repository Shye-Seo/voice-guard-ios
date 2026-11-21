import Foundation

// MARK: - 매핑된 전사 구간

/// 격양 구간 타임라인과 매핑된 발화 1구간.
///
/// 리포트 UI는 이 구조체만 읽으면 되도록, 어떤 격양 이벤트와 얼마나 겹쳤는지를
/// 전사 시점에 미리 계산해 둔다(렌더링 때 다시 계산하지 않는다).
public struct AnnotatedTranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var startedAtOffset: TimeInterval
    public var endedAtOffset: TimeInterval
    public var confidence: Double
    /// 겹친 격양 이벤트 중 최고 격양도
    public var agitationPeakScore: Double
    /// 격양 이벤트와 겹친 총 시간(초)
    public var agitationOverlapSeconds: TimeInterval
    /// 겹친 격양 이벤트 인덱스(`RecordingSessionRecord.agitationEvents` 기준)
    public var eventIndexes: [Int]
    /// 이 발화가 격양 구간에 속하는지(겹침이 임계 이상)
    public var isAgitated: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        startedAtOffset: TimeInterval,
        endedAtOffset: TimeInterval,
        confidence: Double = 0.0,
        agitationPeakScore: Double = 0.0,
        agitationOverlapSeconds: TimeInterval = 0.0,
        eventIndexes: [Int] = [],
        isAgitated: Bool = false
    ) {
        self.id = id
        self.text = text
        self.startedAtOffset = startedAtOffset
        self.endedAtOffset = endedAtOffset
        self.confidence = confidence
        self.agitationPeakScore = max(0, agitationPeakScore)
        self.agitationOverlapSeconds = max(0, agitationOverlapSeconds)
        self.eventIndexes = eventIndexes
        self.isAgitated = isAgitated
    }

    public var durationSeconds: TimeInterval {
        max(0, endedAtOffset - startedAtOffset)
    }
}

// MARK: - 핵심 쟁점 · 키워드 · 마커

/// 격양이 가장 심했던 핵심 발언.
public struct KeyClaim: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var startedAtOffset: TimeInterval
    public var endedAtOffset: TimeInterval
    /// 이 발언과 겹친 격양 이벤트의 최고 격양도(0.0 ~ 1.0)
    public var peakAgitationScore: Double
    public var agitationOverlapSeconds: TimeInterval
    /// 대응하는 격양 이벤트 인덱스(없으면 nil)
    public var eventIndex: Int?
    /// 최고 격양 이벤트와 발화가 직접 겹치지 않고 가장 가까운 발화로 대체되었는지
    public var isNearestFallback: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        startedAtOffset: TimeInterval,
        endedAtOffset: TimeInterval,
        peakAgitationScore: Double,
        agitationOverlapSeconds: TimeInterval,
        eventIndex: Int?,
        isNearestFallback: Bool = false
    ) {
        self.id = id
        self.text = text
        self.startedAtOffset = startedAtOffset
        self.endedAtOffset = endedAtOffset
        self.peakAgitationScore = peakAgitationScore
        self.agitationOverlapSeconds = agitationOverlapSeconds
        self.eventIndex = eventIndex
        self.isNearestFallback = isNearestFallback
    }

    public var durationSeconds: TimeInterval {
        max(0, endedAtOffset - startedAtOffset)
    }
}

/// 반복 키워드 1건. `weight`는 격양 구간 발화에 가중치를 준 점수다.
public struct KeywordStat: Identifiable, Codable, Equatable, Sendable {
    public var term: String
    public var count: Int
    public var weight: Double

    public var id: String { term }

    public init(term: String, count: Int, weight: Double) {
        self.term = term
        self.count = count
        self.weight = weight
    }
}

public enum EpisodeTimelineMarkerKind: String, Codable, Sendable {
    /// 격양이 가장 심했던 발언 지점
    case keyClaim
    /// 격양 구간 피크 지점
    case agitationPeak
}

/// 타임라인 마커 1건. `offset`은 녹음 시작 기준 상대 초.
public struct EpisodeTimelineMarker: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: EpisodeTimelineMarkerKind
    public var offset: TimeInterval
    public var label: String
    public var agitationScore: Double

    public init(
        id: UUID = UUID(),
        kind: EpisodeTimelineMarkerKind,
        offset: TimeInterval,
        label: String,
        agitationScore: Double = 0.0
    ) {
        self.id = id
        self.kind = kind
        self.offset = max(0, offset)
        self.label = label
        self.agitationScore = max(0, agitationScore)
    }
}

// MARK: - 요약 · 리포트

/// 한 녹음의 전사 기반 요약(핵심 쟁점·키워드·발화/격양 시간·타임라인 마커).
public struct EpisodeSummary: Codable, Equatable, Sendable {
    /// 한 문단 요약(발화 시간·격양 시간·핵심 쟁점·키워드)
    public var headline: String
    public var keyClaim: KeyClaim?
    public var keywords: [KeywordStat]
    /// 발화가 있던 총 시간(초)
    public var speechSeconds: TimeInterval
    public var segmentCount: Int
    /// 격양 구간에 속한 발화의 총 길이(초).
    public var agitatedSpeechSeconds: TimeInterval
    /// 녹음 전체의 격양 구간 합계(초)
    public var agitationSeconds: TimeInterval
    public var agitationEventCount: Int
    public var markers: [EpisodeTimelineMarker]
    public var generatedAt: Date
    public var engineName: String

    public init(
        headline: String,
        keyClaim: KeyClaim? = nil,
        keywords: [KeywordStat] = [],
        speechSeconds: TimeInterval = 0,
        segmentCount: Int = 0,
        agitatedSpeechSeconds: TimeInterval = 0,
        agitationSeconds: TimeInterval = 0,
        agitationEventCount: Int = 0,
        markers: [EpisodeTimelineMarker] = [],
        generatedAt: Date = Date(),
        engineName: String = ""
    ) {
        self.headline = headline
        self.keyClaim = keyClaim
        self.keywords = keywords
        self.speechSeconds = max(0, speechSeconds)
        self.segmentCount = max(0, segmentCount)
        self.agitatedSpeechSeconds = max(0, agitatedSpeechSeconds)
        self.agitationSeconds = max(0, agitationSeconds)
        self.agitationEventCount = max(0, agitationEventCount)
        self.markers = markers
        self.generatedAt = generatedAt
        self.engineName = engineName
    }
}

/// 한 녹음의 전사 타임라인 + 쟁점 요약. 상세 화면에서 그대로 저장·공유한다.
public struct EpisodeReport: Codable, Equatable, Sendable {
    public var recordID: UUID
    public var transcript: [AnnotatedTranscriptSegment]
    public var summary: EpisodeSummary

    public init(recordID: UUID, transcript: [AnnotatedTranscriptSegment], summary: EpisodeSummary) {
        self.recordID = recordID
        self.transcript = transcript
        self.summary = summary
    }

    public var hasTranscript: Bool { !transcript.isEmpty }
    public var hasAgitatedSpeech: Bool { transcript.contains { $0.isAgitated } }
}

/// 재생성해도 값이 바뀌지 않는 식별자. 같은 논거으로 두 번 요약해도 동일한 리포트가 나오도록 한다.
enum StableIdentifier {
    static func make(_ seed: String) -> UUID {
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x9e37_79b9_7f4a_7c15
        for scalar in seed.unicodeScalars {
            first = (first ^ UInt64(scalar.value)) &* 0x0000_0100_0000_01b3
            second = (second &+ UInt64(scalar.value)) &* 0x0000_0100_0000_01b3
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((first >> (8 * UInt64(index))) & 0xff)
            bytes[8 + index] = UInt8((second >> (8 * UInt64(index))) & 0xff)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - 요약 설정

public struct EpisodeSummarizerConfiguration: Equatable, Sendable {
    /// 발화를 격양 구간으로 인정하는 최소 겹침(초). 이보다 짧게 스치는 구간은 제외한다.
    public var minimumAgitationOverlapSeconds: TimeInterval
    /// 격양 구간 발화에 곱하는 키워드 가중치
    public var agitatedKeywordWeight: Double
    public var maximumKeywords: Int
    public var maximumMarkers: Int
    public var minimumKeywordLength: Int
    /// 핵심 발언 인용문 최대 길이(글자)
    public var quoteLimit: Int
    public var stopwords: Set<String>

    public init(
        minimumAgitationOverlapSeconds: TimeInterval = 0.2,
        agitatedKeywordWeight: Double = 2.0,
        maximumKeywords: Int = 5,
        maximumMarkers: Int = 20,
        minimumKeywordLength: Int = 2,
        quoteLimit: Int = 40,
        stopwords: Set<String> = EpisodeSummarizerConfiguration.defaultStopwords
    ) {
        self.minimumAgitationOverlapSeconds = max(0, minimumAgitationOverlapSeconds)
        self.agitatedKeywordWeight = max(1.0, agitatedKeywordWeight)
        self.maximumKeywords = max(0, maximumKeywords)
        self.maximumMarkers = max(1, maximumMarkers)
        self.minimumKeywordLength = max(1, minimumKeywordLength)
        self.quoteLimit = max(8, quoteLimit)
        self.stopwords = stopwords
    }

    public static let defaultStopwords: Set<String> = [
        // 한국어 기능어·감탄사
        "그", "저", "것", "수", "때", "좀", "더", "안", "못", "뭐", "왜", "응", "네", "예", "아", "어", "음",
        "이거", "그거", "저거", "그냥", "진짜", "정말", "너무", "많이", "다시", "이제", "아직", "또", "및", "등",
        "거", "건", "게", "듯", "분", "쪽", "중", "위해", "대해", "대한", "관해",
        "하고", "하는", "한다", "했다", "해서", "하면", "하지", "합니다", "입니다",
        "있어", "없어", "있다", "없다", "같아", "같은", "그리고", "그런데", "근데", "하지만", "그래서", "그러면", "그럼",
        "너", "나", "우리", "당신", "제가", "내가", "니가", "네가", "저는", "나는",
        // 영어 기능어
        "the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "at", "is", "are", "was", "were",
        "i", "you", "we", "it", "this", "that", "yeah", "ok", "okay", "um", "uh"
    ]
}

// MARK: - 요약기

/// 격양 타임라인 + 전사 세그먼트를 결합해 핵심 쟁점 요약을 만든다.
///
/// 순수 함수에 가깝게 설계해, 같은 입력·같은 `generatedAt`이면 항상 같은 결과가 나온다
/// (테스트·`scripts/verify_dsp.py` 미러가 같은 값을 검증한다).
public struct EpisodeSummarizer {
    public let configuration: EpisodeSummarizerConfiguration

    public init(configuration: EpisodeSummarizerConfiguration = EpisodeSummarizerConfiguration()) {
        self.configuration = configuration
    }

    /// 전사 결과를 격양 타임라인에 매핑한다.
    public func annotate(
        segments: [SpeechTranscriptSegment],
        events: [AgitationEvent],
        duration: TimeInterval? = nil
    ) -> [AnnotatedTranscriptSegment] {
        let normalized = SpeechTranscriptNormalizer.normalize(segments, duration: duration)
        return normalized.map { segment in
            var peakScore = 0.0
            var overlapTotal = 0.0
            var indexes: [Int] = []
            for (index, event) in events.enumerated() {
                let overlap = segment.overlapSeconds(with: event)
                guard overlap > 0 else { continue }
                overlapTotal += overlap
                indexes.append(index)
                peakScore = max(peakScore, event.peakScore)
            }
            let isAgitated = overlapTotal >= configuration.minimumAgitationOverlapSeconds
                && !indexes.isEmpty
            return AnnotatedTranscriptSegment(
                id: segment.id,
                text: segment.text,
                startedAtOffset: segment.startedAtOffset,
                endedAtOffset: segment.endedAtOffset,
                confidence: segment.confidence,
                agitationPeakScore: isAgitated ? peakScore : 0.0,
                agitationOverlapSeconds: overlapTotal,
                eventIndexes: indexes,
                isAgitated: isAgitated
            )
        }
    }

    /// 전사 결과로부터 리포트를 만든다.
    public func makeReport(
        record: RecordingSessionRecord,
        segments: [SpeechTranscriptSegment],
        engineName: String,
        generatedAt: Date = Date()
    ) -> EpisodeReport {
        let transcript = annotate(
            segments: segments,
            events: record.agitationEvents,
            duration: record.durationSeconds > 0 ? record.durationSeconds : nil
        )
        let summary = summarize(
            record: record,
            transcript: transcript,
            engineName: engineName,
            generatedAt: generatedAt
        )
        return EpisodeReport(recordID: record.id, transcript: transcript, summary: summary)
    }

    /// 매핑된 전사 구간으로 요약을 계산한다(재요약·테스트 경로).
    public func summarize(
        record: RecordingSessionRecord,
        transcript: [AnnotatedTranscriptSegment],
        engineName: String,
        generatedAt: Date = Date()
    ) -> EpisodeSummary {
        let keyClaim = selectKeyClaim(
            recordID: record.id,
            transcript: transcript,
            events: record.agitationEvents
        )
        let keywords = extractKeywords(from: transcript)
        let speechSeconds = transcript.reduce(0.0) { $0 + $1.durationSeconds }
        let agitatedSpeechSeconds = transcript
            .filter { $0.isAgitated }
            .reduce(0.0) { $0 + $1.durationSeconds }
        let markers = makeMarkers(
            recordID: record.id,
            transcript: transcript,
            events: record.agitationEvents,
            keyClaim: keyClaim
        )
        let headline = EpisodeReportFormatter.headline(
            speechSeconds: speechSeconds,
            segmentCount: transcript.count,
            agitationSeconds: record.agitatedSeconds,
            agitationEventCount: record.agitationEvents.count,
            keyClaim: keyClaim,
            keywords: keywords
        )
        return EpisodeSummary(
            headline: headline,
            keyClaim: keyClaim,
            keywords: keywords,
            speechSeconds: speechSeconds,
            segmentCount: transcript.count,
            agitatedSpeechSeconds: agitatedSpeechSeconds,
            agitationSeconds: record.agitatedSeconds,
            agitationEventCount: record.agitationEvents.count,
            markers: markers,
            generatedAt: generatedAt,
            engineName: engineName
        )
    }

    // MARK: 핵심 발언

    private func selectKeyClaim(
        recordID: UUID,
        transcript: [AnnotatedTranscriptSegment],
        events: [AgitationEvent]
    ) -> KeyClaim? {
        guard !transcript.isEmpty else { return nil }

        let agitated = transcript.filter { $0.isAgitated }
        if let best = agitated.reduce(nil as AnnotatedTranscriptSegment?, { current, candidate in
            guard let current else { return candidate }
            return isStronger(candidate, than: current) ? candidate : current
        }) {
            let eventIndex = best.eventIndexes.max { lhs, rhs in
                events[lhs].peakScore < events[rhs].peakScore
            }
            return KeyClaim(
                id: StableIdentifier.make("claim|\(recordID)|\(best.startedAtOffset)|\(best.text)"),
                text: best.text,
                startedAtOffset: best.startedAtOffset,
                endedAtOffset: best.endedAtOffset,
                peakAgitationScore: best.agitationPeakScore,
                agitationOverlapSeconds: best.agitationOverlapSeconds,
                eventIndex: eventIndex,
                isNearestFallback: false
            )
        }

        // 격양 구간과 직접 겹치는 발화가 없으면, 가장 격양이 심했던 이벤트에 가장 가까운 발화를 쓴다.
        guard let peakEventIndex = events.indices.max(by: { events[$0].peakScore < events[$1].peakScore }) else {
            return nil
        }
        let peakEvent = events[peakEventIndex]
        let nearest = transcript.min { lhs, rhs in
            let lhsGap = gap(between: lhs, and: peakEvent)
            let rhsGap = gap(between: rhs, and: peakEvent)
            if lhsGap != rhsGap { return lhsGap < rhsGap }
            return lhs.startedAtOffset < rhs.startedAtOffset
        }
        guard let nearest else { return nil }
        return KeyClaim(
            id: StableIdentifier.make("claim|\(recordID)|\(nearest.startedAtOffset)|\(nearest.text)"),
            text: nearest.text,
            startedAtOffset: nearest.startedAtOffset,
            endedAtOffset: nearest.endedAtOffset,
            peakAgitationScore: peakEvent.peakScore,
            agitationOverlapSeconds: nearest.agitationOverlapSeconds,
            eventIndex: peakEventIndex,
            isNearestFallback: true
        )
    }

    private func isStronger(
        _ lhs: AnnotatedTranscriptSegment,
        than rhs: AnnotatedTranscriptSegment
    ) -> Bool {
        if lhs.agitationPeakScore != rhs.agitationPeakScore {
            return lhs.agitationPeakScore > rhs.agitationPeakScore
        }
        if lhs.agitationOverlapSeconds != rhs.agitationOverlapSeconds {
            return lhs.agitationOverlapSeconds > rhs.agitationOverlapSeconds
        }
        return lhs.startedAtOffset < rhs.startedAtOffset
    }

    private func gap(between segment: AnnotatedTranscriptSegment, and event: AgitationEvent) -> TimeInterval {
        if segment.endedAtOffset < event.startedAtOffset {
            return event.startedAtOffset - segment.endedAtOffset
        }
        if segment.startedAtOffset > event.endedAtOffset {
            return segment.startedAtOffset - event.endedAtOffset
        }
        return 0
    }

    // MARK: 키워드

    private func extractKeywords(from transcript: [AnnotatedTranscriptSegment]) -> [KeywordStat] {
        guard configuration.maximumKeywords > 0 else { return [] }
        var counts: [String: Int] = [:]
        var weights: [String: Double] = [:]

        for segment in transcript {
            let increment = segment.isAgitated ? configuration.agitatedKeywordWeight : 1.0
            for token in Self.tokenize(segment.text) {
                let base = Self.stem(token)
                // 조사를 떼면 1글자만 남는 단어는 원형을 유지하되, 원형이 기능어면 버린다.
                let term = base.count >= configuration.minimumKeywordLength ? base : token
                guard Self.isMeaningful(
                    term,
                    base: base,
                    minimumLength: configuration.minimumKeywordLength,
                    stopwords: configuration.stopwords
                ) else { continue }
                counts[term, default: 0] += 1
                weights[term, default: 0] += increment
            }
        }

        return counts.map { term, count in
            KeywordStat(term: term, count: count, weight: weights[term] ?? Double(count))
        }
        .sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.term < rhs.term
        }
        .prefix(configuration.maximumKeywords)
        .map { $0 }
    }

    /// 공백·문장부호 기준 토큰화(한국어 조사는 `stem`에서 떼어낸다).
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var buffer = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                buffer.unicodeScalars.append(scalar)
            } else if !buffer.isEmpty {
                tokens.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { tokens.append(buffer) }
        return tokens
    }

    /// 한국어 조사·어미를 한 번만 떼어낸다("약속을" → "약속").
    static func stem(_ token: String) -> String {
        for suffix in koreanSuffixes where token.count > suffix.count && token.hasSuffix(suffix) {
            return String(token.dropLast(suffix.count))
        }
        return token
    }

    static func isMeaningful(
        _ term: String,
        base: String,
        minimumLength: Int,
        stopwords: Set<String>
    ) -> Bool {
        guard term.count >= minimumLength else { return false }
        guard !stopwords.contains(term), !stopwords.contains(base) else { return false }
        guard term.contains(where: { $0.isLetter }) else { return false }
        return true
    }

    /// 긴 조사부터 검사해야 "에서는"이 "에"로 잘리지 않는다.
    static let koreanSuffixes: [String] = [
        "에서는", "에서도", "에게는", "으로는", "으로서", "이라는", "이라서", "이라고", "라는", "라고",
        "합니다", "입니다", "했는데", "하다가", "했어요", "하는데", "했어", "한다", "했다", "해서", "하면",
        "하고", "하지", "인데", "이며", "이고", "이나", "라도", "든지", "까지", "부터", "보다", "처럼",
        "마다", "조차", "밖에", "한테", "에게", "에서", "으로", "로서", "이랑", "와는", "과는",
        "은", "는", "이", "가", "을", "를", "에", "의", "도", "와", "과", "로", "만", "께", "랑", "야", "아", "요", "죠", "네"
    ]

    // MARK: 타임라인 마커

    private func makeMarkers(
        recordID: UUID,
        transcript: [AnnotatedTranscriptSegment],
        events: [AgitationEvent],
        keyClaim: KeyClaim?
    ) -> [EpisodeTimelineMarker] {
        var markers: [EpisodeTimelineMarker] = []

        if let keyClaim {
            markers.append(
                EpisodeTimelineMarker(
                    id: StableIdentifier.make("marker|claim|\(recordID)|\(keyClaim.startedAtOffset)|\(keyClaim.text)"),
                    kind: .keyClaim,
                    offset: keyClaim.startedAtOffset,
                    label: EpisodeReportFormatter.quote(keyClaim.text, limit: configuration.quoteLimit),
                    agitationScore: keyClaim.peakAgitationScore
                )
            )
        }

        for (eventIndex, event) in events.enumerated() {
            // 피크 시각은 이벤트 안에서 가장 격양도가 높았던 발화의 시작을 우선 사용한다.
            let overlapping = transcript.filter { segment in
                segment.eventIndexes.contains(eventIndex)
            }
            let peakSegment = overlapping.max { lhs, rhs in
                if lhs.agitationPeakScore != rhs.agitationPeakScore {
                    return lhs.agitationPeakScore < rhs.agitationPeakScore
                }
                return lhs.agitationOverlapSeconds < rhs.agitationOverlapSeconds
            }
            let offset = peakSegment?.startedAtOffset
                ?? (event.startedAtOffset + event.durationSeconds * 0.5)
            let label = peakSegment.map {
                EpisodeReportFormatter.quote($0.text, limit: configuration.quoteLimit)
            } ?? "발화 없음 (비언어성 격양)"
            markers.append(
                EpisodeTimelineMarker(
                    id: StableIdentifier.make("marker|peak|\(recordID)|\(eventIndex)|\(offset)"),
                    kind: .agitationPeak,
                    offset: offset,
                    label: label,
                    agitationScore: event.peakScore
                )
            )
        }

        let sorted = markers.sorted { lhs, rhs in
            if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
            if lhs.agitationScore != rhs.agitationScore { return lhs.agitationScore > rhs.agitationScore }
            return lhs.kind == .keyClaim && rhs.kind != .keyClaim
        }
        return Array(sorted.prefix(configuration.maximumMarkers))
    }
}

// MARK: - 포매터

/// 리포트 UI·공유 텍스트용 포매터.
public enum EpisodeReportFormatter {
    /// "1분 12초" / "48.2초"
    public static func durationText(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped >= 60 {
            let minutes = Int(clamped) / 60
            let remainder = Int((clamped - Double(minutes * 60)).rounded())
            return "\(minutes)분 \(remainder)초"
        }
        return String(format: "%.1f초", clamped)
    }

    /// 인용문을 한 줄로 정리하고 최대 길이에서 자른다.
    public static func quote(_ text: String, limit: Int = 40) -> String {
        let collapsed = SpeechTranscriptNormalizer.collapseWhitespace(text)
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// 한 문단 요약. 발화/격양 시간 → 핵심 쟁점 → 반복 키워드 순.
    public static func headline(
        speechSeconds: TimeInterval,
        segmentCount: Int,
        agitationSeconds: TimeInterval,
        agitationEventCount: Int,
        keyClaim: KeyClaim?,
        keywords: [KeywordStat]
    ) -> String {
        var parts: [String] = []

        if segmentCount > 0 {
            parts.append("발화 \(durationText(speechSeconds))(\(segmentCount)구간)")
        } else {
            parts.append("발화 없음")
        }

        if agitationEventCount > 0 {
            parts.append("격양 \(durationText(agitationSeconds)) (\(agitationEventCount)구간)")
        } else {
            parts.append("격양 구간 없음")
        }

        if let keyClaim {
            let time = SessionReportFormatter.timestampText(keyClaim.startedAtOffset)
            let prefix = keyClaim.isNearestFallback ? "가장 격양이 심했던 구간 근처 발언" : "가장 격양이 심했던 발언"
            let quote = quote(keyClaim.text)
            parts.append("\(prefix): \(time) 「\(quote)」")
        } else if segmentCount > 0 {
            parts.append("격양 구간에 해당하는 발화를 찾지 못했습니다")
        }

        if !keywords.isEmpty {
            let terms = keywords.prefix(3).map { "'\($0.term)'" }.joined(separator: ", ")
            parts.append("반복 키워드: \(terms)")
        }

        return parts.joined(separator: " · ")
    }

    /// 공유·복사용 리포트 본문(전사 타임라인 + 쟁점 요약).
    public static func reportText(for report: EpisodeReport, maximumTranscriptLines: Int = 40) -> String {
        let summary = report.summary
        var lines: [String] = []
        lines.append("[VoiceGuard 전사·쟁점 요약]")
        lines.append("녹음 ID: \(report.recordID.uuidString)")
        lines.append("생성: \(SessionReportFormatter.dateText(summary.generatedAt))")
        lines.append("엔진: \(summary.engineName)")
        lines.append("")
        lines.append("[요약]")
        lines.append(summary.headline)

        if !summary.keywords.isEmpty {
            lines.append("")
            lines.append("[반복 키워드]")
            for keyword in summary.keywords {
                lines.append(String(format: "· %@ (%d회, 가중 %.1f)", keyword.term, keyword.count, keyword.weight))
            }
        }

        if let keyClaim = summary.keyClaim {
            lines.append("")
            lines.append("[핵심 쟁점 발언]")
            lines.append(
                "· \(SessionReportFormatter.timestampText(keyClaim.startedAtOffset)) ~ "
                + "\(SessionReportFormatter.timestampText(keyClaim.endedAtOffset)) "
                + "(격양도 \(Int((keyClaim.peakAgitationScore * 100).rounded()))%)"
            )
            lines.append("· \"\(keyClaim.text)\"")
        }

        if !summary.markers.isEmpty {
            lines.append("")
            lines.append("[타임라인 마커]")
            for marker in summary.markers {
                let kind = marker.kind == .keyClaim ? "핵심 쟁점" : "격양 피크"
                lines.append(
                    "· \(SessionReportFormatter.timestampText(marker.offset)) [\(kind)] \(marker.label)"
                )
            }
        }

        if !report.transcript.isEmpty {
            lines.append("")
            lines.append("[전사 타임라인]")
            for segment in report.transcript.prefix(maximumTranscriptLines) {
                let mark = segment.isAgitated ? "❗️" : "·"
                lines.append(
                    "\(mark) \(SessionReportFormatter.timestampText(segment.startedAtOffset)) "
                    + "\(segment.text)"
                )
            }
            if report.transcript.count > maximumTranscriptLines {
                lines.append("· 외 \(report.transcript.count - maximumTranscriptLines)구간")
            }
        }

        lines.append("")
        lines.append("음성 인식과 요약은 모두 기기 내부(온디바이스)에서만 수행되었습니다.")
        return lines.joined(separator: "\n")
    }
}
