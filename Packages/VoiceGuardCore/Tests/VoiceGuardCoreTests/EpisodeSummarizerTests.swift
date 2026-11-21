import XCTest
@testable import VoiceGuardCore

final class EpisodeSummarizerTests: XCTestCase {
    // MARK: - 공통 픽스처

    /// 72초 대화: 격양 3구간, 발화 8구간. 모든 기대값은 이 픽스처 기준으로 계산한다.
    private func makeFixture() -> (RecordingSessionRecord, [SpeechTranscriptSegment]) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = RecordingSessionRecord(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            fileName: "vg_episode.m4a",
            startedAt: now,
            endedAt: now.addingTimeInterval(72),
            durationSeconds: 72,
            peakAgitationScore: 0.93,
            triggerReason: "성량 +19dB · 고음 피치(298Hz) 급등",
            peakRMSDB: -12.4,
            averageRMSDB: -38.1,
            maxPitchHz: 298,
            agitatedSeconds: 9.4,
            agitationEvents: [
                AgitationEvent(startedAtOffset: 5.0, endedAtOffset: 8.1, peakScore: 0.93, peakRMSDB: -12.4, peakPitchHz: 298),
                AgitationEvent(startedAtOffset: 22.5, endedAtOffset: 25.8, peakScore: 0.88, peakRMSDB: -14.1, peakPitchHz: 271),
                AgitationEvent(startedAtOffset: 41.0, endedAtOffset: 44.0, peakScore: 0.71, peakRMSDB: -19.6, peakPitchHz: 244)
            ],
            levelEnvelope: [],
            envelopeBucketSeconds: 0.5
        )

        let segments = [
            SpeechTranscriptSegment(text: "오늘 저녁에 뭐 먹을지 이야기해 보자", startedAtOffset: 0.0, endedAtOffset: 3.4, confidence: 0.9),
            SpeechTranscriptSegment(text: "너는 또 약속 시간을 어겼잖아", startedAtOffset: 4.2, endedAtOffset: 7.0, confidence: 0.95),
            SpeechTranscriptSegment(text: "지난번에도 약속을 지키지 않았어", startedAtOffset: 7.6, endedAtOffset: 10.2, confidence: 0.9),
            SpeechTranscriptSegment(text: "그건 내가 회사 일이 있어서 그런 거야", startedAtOffset: 12.0, endedAtOffset: 16.0, confidence: 0.85),
            SpeechTranscriptSegment(text: "약속이라는 건 서로 지켜야 하는 거야", startedAtOffset: 21.0, endedAtOffset: 23.4, confidence: 0.88),
            SpeechTranscriptSegment(text: "알았어 다음엔 시간 지킬게", startedAtOffset: 24.0, endedAtOffset: 26.5, confidence: 0.86),
            SpeechTranscriptSegment(text: "그렇게 말하면 나는 항상 시간에 늦는 사람이 돼", startedAtOffset: 40.0, endedAtOffset: 43.2, confidence: 0.83),
            SpeechTranscriptSegment(text: "오늘은 그만 싸우고 밥 먹자", startedAtOffset: 50.0, endedAtOffset: 54.0, confidence: 0.92)
        ]
        return (record, segments)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_600)

    // MARK: - 전사 구간 ↔ 격양 구간 매핑

    func testAnnotateMapsSegmentsToOverlappingAgitationEvents() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let transcript = summarizer.annotate(segments: segments, events: record.agitationEvents)

        XCTAssertEqual(transcript.count, 8)
        XCTAssertEqual(transcript[1].eventIndexes, [0])
        XCTAssertTrue(transcript[1].isAgitated)
        XCTAssertEqual(transcript[1].agitationOverlapSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(transcript[1].agitationPeakScore, 0.93, accuracy: 0.001)

        XCTAssertFalse(transcript[0].isAgitated)
        XCTAssertTrue(transcript[0].eventIndexes.isEmpty)
        XCTAssertEqual(transcript[0].agitationOverlapSeconds, 0, accuracy: 0.001)

        XCTAssertTrue(transcript[4].isAgitated)
        XCTAssertEqual(transcript[4].eventIndexes, [1])
        XCTAssertEqual(transcript[6].eventIndexes, [2])
    }

    func testShortOverlapBelowThresholdIsNotAgitated() {
        let summarizer = EpisodeSummarizer(
            configuration: EpisodeSummarizerConfiguration(minimumAgitationOverlapSeconds: 1.0)
        )
        let segments = [
            SpeechTranscriptSegment(text: "잠깐만 기다려", startedAtOffset: 4.9, endedAtOffset: 5.5)
        ]
        let event = AgitationEvent(startedAtOffset: 5.0, endedAtOffset: 8.0, peakScore: 0.9, peakRMSDB: -12, peakPitchHz: 300)
        let transcript = summarizer.annotate(segments: segments, events: [event])

        XCTAssertEqual(transcript[0].agitationOverlapSeconds, 0.5, accuracy: 0.001)
        XCTAssertFalse(transcript[0].isAgitated)
        XCTAssertEqual(transcript[0].eventIndexes, [0])
        XCTAssertEqual(transcript[0].agitationPeakScore, 0, accuracy: 0.001)
    }

    func testAnnotateNormalizesOrderAndClampsToDuration() {
        let summarizer = EpisodeSummarizer()
        let segments = [
            SpeechTranscriptSegment(text: "두 번째", startedAtOffset: 12, endedAtOffset: 14),
            SpeechTranscriptSegment(text: "   ", startedAtOffset: 5, endedAtOffset: 6),
            SpeechTranscriptSegment(text: "첫 번째", startedAtOffset: 1, endedAtOffset: 2),
            SpeechTranscriptSegment(text: "길이 초과", startedAtOffset: 69, endedAtOffset: 80)
        ]
        let transcript = summarizer.annotate(segments: segments, events: [], duration: 70)

        XCTAssertEqual(transcript.map(\.text), ["첫 번째", "두 번째", "길이 초과"])
        XCTAssertEqual(transcript.last?.endedAtOffset, 70)
    }

    // MARK: - 핵심 쟁점

    func testKeyClaimIsTheMostAgitatedUtterance() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let report = summarizer.makeReport(
            record: record,
            segments: segments,
            engineName: "Scripted (deterministic)",
            generatedAt: fixedDate
        )

        let keyClaim = try! XCTUnwrap(report.summary.keyClaim)
        XCTAssertEqual(keyClaim.text, "너는 또 약속 시간을 어겼잖아")
        XCTAssertEqual(keyClaim.startedAtOffset, 4.2, accuracy: 0.001)
        XCTAssertEqual(keyClaim.peakAgitationScore, 0.93, accuracy: 0.001)
        XCTAssertEqual(keyClaim.eventIndex, 0)
        XCTAssertFalse(keyClaim.isNearestFallback)
    }

    func testKeyClaimFallsBackToNearestUtteranceWhenNothingOverlaps() {
        let (record, _) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let segments = [
            SpeechTranscriptSegment(text: "이른 발화", startedAtOffset: 15, endedAtOffset: 17),
            SpeechTranscriptSegment(text: "늦은 발화", startedAtOffset: 30, endedAtOffset: 32)
        ]
        // 격양 이벤트(5.0~8.1, 최고 격양도)와 가장 가까운 발화를 핵심 쟁점으로 올린다.
        let report = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)

        let keyClaim = try! XCTUnwrap(report.summary.keyClaim)
        XCTAssertEqual(keyClaim.text, "이른 발화")
        XCTAssertTrue(keyClaim.isNearestFallback)
        XCTAssertEqual(keyClaim.eventIndex, 0)
        XCTAssertFalse(report.hasAgitatedSpeech)
    }

    func testEmptyTranscriptStillReportsAgitationWithoutKeyClaim() {
        let (record, _) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let report = summarizer.makeReport(record: record, segments: [], engineName: "test", generatedAt: fixedDate)

        XCTAssertTrue(report.transcript.isEmpty)
        XCTAssertNil(report.summary.keyClaim)
        XCTAssertTrue(report.summary.keywords.isEmpty)
        XCTAssertEqual(report.summary.speechSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(report.summary.agitationSeconds, 9.4, accuracy: 0.001)
        XCTAssertTrue(report.summary.headline.contains("발화 없음"))
        XCTAssertTrue(report.summary.headline.contains("격양"))
    }

    // MARK: - 요약 수치

    func testSummaryTotalsSpeechAndAgitatedSpeech() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let report = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)

        XCTAssertEqual(report.summary.segmentCount, 8)
        XCTAssertEqual(report.summary.speechSeconds, 24.9, accuracy: 0.01)
        XCTAssertEqual(report.summary.agitatedSpeechSeconds, 13.5, accuracy: 0.01)
        XCTAssertEqual(report.summary.agitationSeconds, 9.4, accuracy: 0.01)
        XCTAssertEqual(report.summary.agitationEventCount, 3)
    }

    func testSummaryIsDeterministicForSameInputAndDate() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let first = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)
        let second = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)

        XCTAssertEqual(first.transcript.map(\.text), second.transcript.map(\.text))
        XCTAssertEqual(first.summary, second.summary)
    }

    // MARK: - 키워드

    func testKeywordsStripKoreanParticlesAndRankByWeightedCount() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let report = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)

        let terms = report.summary.keywords.map(\.term)
        XCTAssertEqual(Array(terms.prefix(2)), ["시간", "약속"], "격양 발화에서 3회씩 등장한 키워드가 먼저 와야 한다")

        let promise = try! XCTUnwrap(report.summary.keywords.first { $0.term == "약속" })
        XCTAssertEqual(promise.count, 3)
        XCTAssertEqual(promise.weight, 6.0, accuracy: 0.001)

        XCTAssertFalse(terms.contains("약속을"))
        XCTAssertFalse(terms.contains("시간을"))
        XCTAssertFalse(terms.contains("또"))
    }

    func testKeywordsIgnoreStopwordsAndPlaceholders() {
        let record = RecordingSessionRecord(
            fileName: "vg_stop.m4a",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_010),
            durationSeconds: 10,
            peakAgitationScore: 0,
            triggerReason: "테스트"
        )
        let segments = [
            SpeechTranscriptSegment(text: "그냥 그래서 그리고 진짜 너무 그거 뭐야", startedAtOffset: 0, endedAtOffset: 3)
        ]
        let summarizer = EpisodeSummarizer()
        let report = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)
        XCTAssertTrue(report.summary.keywords.isEmpty)
    }

    func testKeywordLimitIsApplied() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer(configuration: EpisodeSummarizerConfiguration(maximumKeywords: 3))
        let report = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)
        XCTAssertEqual(report.summary.keywords.count, 3)
    }

    // MARK: - 타임라인 마커

    func testTimelineMarkersAreSortedAndIncludeKeyClaimAndPeaks() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let report = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)

        let markers = report.summary.markers
        XCTAssertEqual(markers.count, 4)
        XCTAssertEqual(markers.map(\.kind), [.keyClaim, .agitationPeak, .agitationPeak, .agitationPeak])
        XCTAssertEqual(markers[0].offset, 4.2, accuracy: 0.001)
        XCTAssertEqual(markers[1].offset, 4.2, accuracy: 0.001, "첫 격양 이벤트의 피크 발화가 핵심 발화와 같다")
        XCTAssertEqual(markers[2].offset, 24.0, accuracy: 0.001, "두 번째 이벤트는 겹침이 긴 발화를 피크로 잡는다")
        XCTAssertEqual(markers[3].offset, 40.0, accuracy: 0.001)

        // 오프셋 오름차순
        let offsets = markers.map(\.offset)
        XCTAssertEqual(offsets, offsets.sorted())
    }

    func testMarkerLimitKeepsEarliestMarkers() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer(configuration: EpisodeSummarizerConfiguration(maximumMarkers: 2))
        let report = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)
        XCTAssertEqual(report.summary.markers.count, 2)
        XCTAssertEqual(report.summary.markers[0].offset, 4.2, accuracy: 0.001)
    }

    // MARK: - 문장 생성 · 공유 텍스트

    func testHeadlineMentionsTimesQuoteAndKeywords() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let report = summarizer.makeReport(record: record, segments: segments, engineName: "test", generatedAt: fixedDate)
        let headline = report.summary.headline

        XCTAssertTrue(headline.contains("발화 24.9초(8구간)"))
        XCTAssertTrue(headline.contains("격양 9.4초 (3구간)"))
        XCTAssertTrue(headline.contains("00:04.2"))
        XCTAssertTrue(headline.contains("「너는 또 약속 시간을 어겼잖아」"))
        XCTAssertTrue(headline.contains("반복 키워드"))
    }

    func testReportTextContainsSummaryTranscriptAndPrivacyNotice() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        let report = summarizer.makeReport(
            record: record,
            segments: segments,
            engineName: "Apple SFSpeechRecognizer (on-device, ko_KR)",
            generatedAt: fixedDate
        )
        let text = EpisodeReportFormatter.reportText(for: report)

        XCTAssertTrue(text.contains("[VoiceGuard 전사·쟁점 요약]"))
        XCTAssertTrue(text.contains("[핵심 쟁점 발언]"))
        XCTAssertTrue(text.contains("[타임라인 마커]"))
        XCTAssertTrue(text.contains("[전사 타임라인]"))
        XCTAssertTrue(text.contains("❗️ 00:04.2 너는 또 약속 시간을 어겼잖아"))
        XCTAssertTrue(text.contains("온디바이스"))
        XCTAssertTrue(text.contains("on-device, ko_KR"))
    }

    func testSessionReportIncludesEpisodeSummaryWhenPresent() {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        var recordWithReport = record
        recordWithReport.episodeReport = summarizer.makeReport(
            record: record,
            segments: segments,
            engineName: "test",
            generatedAt: fixedDate
        )

        let text = SessionReportFormatter.reportText(record: recordWithReport)
        XCTAssertTrue(text.contains("[전사·쟁점 요약]"))
        XCTAssertTrue(text.contains("가장 격양이 심했던 발언"))
        XCTAssertTrue(recordWithReport.hasEpisodeReport)
    }

    func testEpisodeReportRoundTripsThroughIndexJSON() throws {
        let (record, segments) = makeFixture()
        let summarizer = EpisodeSummarizer()
        var stored = record
        stored.episodeReport = summarizer.makeReport(
            record: record,
            segments: segments,
            engineName: "test",
            generatedAt: fixedDate
        )

        let data = try JSONEncoder().encode([stored])
        let decoded = try JSONDecoder().decode([RecordingSessionRecord].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].episodeReport, stored.episodeReport)
        XCTAssertEqual(decoded[0].episodeReport?.transcript.count, 8)
        XCTAssertEqual(decoded[0].episodeReport?.summary.keyClaim?.text, "너는 또 약속 시간을 어겼잖아")
    }

    func testLegacyIndexJSONWithoutEpisodeReportDecodesToNil() throws {
        let legacy = Data("""
        [{"id":"11111111-2222-3333-4444-555555555555","fileName":"vg_old.m4a","startedAt":790000000,
          "endedAt":790000012,"durationSeconds":12,"peakAgitationScore":0.77,
          "triggerReason":"성량 +15dB 급등"}]
        """.utf8)
        let records = try JSONDecoder().decode([RecordingSessionRecord].self, from: legacy)
        XCTAssertNil(records[0].episodeReport)
        XCTAssertFalse(records[0].hasEpisodeReport)
    }

    func testReportFormatterEndToEndSmoke() {
        let (record, segments) = makeFixture()
        let report = EpisodeSummarizer().makeReport(
            record: record,
            segments: segments,
            engineName: "test",
            generatedAt: fixedDate
        )
        let text = EpisodeReportFormatter.reportText(for: report)
        XCTAssertGreaterThan(text.count, 100)
        XCTAssertTrue(text.contains("[요약]"))
        XCTAssertTrue(text.contains("[반복 키워드]"))
    }

    func testDurationTextFormatting() {
        XCTAssertEqual(EpisodeReportFormatter.durationText(48.24), "48.2초")
        XCTAssertEqual(EpisodeReportFormatter.durationText(72), "1분 12초")
        XCTAssertEqual(EpisodeReportFormatter.durationText(0), "0.0초")
    }

    func testQuoteTruncatesLongUtterance() {
        let long = String(repeating: "약속", count: 40)
        let quote = EpisodeReportFormatter.quote(long, limit: 10)
        XCTAssertTrue(quote.hasSuffix("…"))
        XCTAssertLessThanOrEqual(quote.count, 11)
    }
}
