import XCTest
@testable import VoiceGuardCore

final class AgitationTimelineTests: XCTestCase {
    private func features(rmsDB: Double, pitchHz: Double = 0, flux: Double = 0.1) -> AudioFrameFeatures {
        AudioFrameFeatures(rmsDB: rmsDB, zeroCrossingRate: 0.2, spectralFlux: flux, estimatedPitchHz: pitchHz)
    }

    func testTimelineMergesShortGapsIntoSingleEvent() {
        let timeline = AgitationTimelineAccumulator(mergeGapSeconds: 1.0)
        var t: TimeInterval = 0

        for _ in 0..<4 {
            timeline.ingest(features: features(rmsDB: -20), score: 0.8, isAgitated: true, continuesEvent: true, offset: t)
            t += 0.05
        }
        // 0.2초 진정
        for _ in 0..<4 {
            timeline.ingest(features: features(rmsDB: -50), score: 0.2, isAgitated: false, continuesEvent: false, offset: t)
            t += 0.05
        }
        // 다시 격양
        for _ in 0..<4 {
            timeline.ingest(features: features(rmsDB: -18), score: 0.9, isAgitated: true, continuesEvent: true, offset: t)
            t += 0.05
        }

        let events = timeline.finalize(at: t)
        XCTAssertEqual(events.count, 1, "짧은 진정 구간이 별도 이벤트로 분리됨")
        XCTAssertEqual(events[0].startedAtOffset, 0.0, accuracy: 0.001)
        XCTAssertGreaterThan(events[0].durationSeconds, 0.4)
        XCTAssertEqual(events[0].peakScore, 0.9, accuracy: 0.0001)
        XCTAssertEqual(events[0].peakRMSDB, -18.0, accuracy: 0.0001)
    }

    func testTimelineSplitsEventsBeyondMergeGap() {
        let timeline = AgitationTimelineAccumulator(mergeGapSeconds: 1.0)
        var t: TimeInterval = 0

        for _ in 0..<4 {
            timeline.ingest(features: features(rmsDB: -20), score: 0.8, isAgitated: true, continuesEvent: true, offset: t)
            t += 0.05
        }
        // 3초 진정
        for _ in 0..<60 {
            timeline.ingest(features: features(rmsDB: -55), score: 0.05, isAgitated: false, continuesEvent: false, offset: t)
            t += 0.05
        }
        for _ in 0..<4 {
            timeline.ingest(features: features(rmsDB: -22), score: 0.75, isAgitated: true, continuesEvent: true, offset: t)
            t += 0.05
        }

        let events = timeline.finalize(at: t)
        XCTAssertEqual(events.count, 2, "mergeGap을 넘긴 구간이 하나로 합쳐짐")
        XCTAssertGreaterThan(events[1].startedAtOffset, events[0].endedAtOffset + 1.0)
    }

    func testSessionAccumulatorCollectsPeaksAndEnvelope() {
        let accumulator = RecordingSessionAccumulator(mergeGapSeconds: 1.0, envelopeBucketSeconds: 0.5, frameDuration: 0.05)
        let detector = AgitationDetector(sensitivity: .medium, cooldownDurationSeconds: 5.0)
        var t: TimeInterval = 0

        // 조용한 구간
        for _ in 0..<20 {
            let f = features(rmsDB: -52, pitchHz: 140)
            let decision = detector.process(features: f, timestamp: t)
            accumulator.ingest(features: f, decision: decision, offset: t)
            t += 0.05
        }
        // 격양 구간 3초
        for _ in 0..<60 {
            let f = features(rmsDB: -14, pitchHz: 300, flux: 0.2)
            let decision = detector.process(features: f, timestamp: t)
            accumulator.ingest(features: f, decision: decision, offset: t)
            t += 0.05
        }
        // 진정 구간
        for _ in 0..<200 {
            let f = features(rmsDB: -50, pitchHz: 0, flux: 0.01)
            let decision = detector.process(features: f, timestamp: t)
            accumulator.ingest(features: f, decision: decision, offset: t)
            t += 0.05
        }

        let summary = accumulator.finalize(at: t)
        XCTAssertEqual(summary.peakRMSDB, -14.0, accuracy: 0.001)
        XCTAssertEqual(summary.maxPitchHz, 300.0, accuracy: 0.001)
        XCTAssertGreaterThan(summary.peakAgitationScore, 0.58)
        XCTAssertFalse(summary.events.isEmpty, "격양 이벤트가 기록되지 않음")
        XCTAssertGreaterThan(summary.agitatedSeconds, 0.5)
        XCTAssertLessThan(summary.averageRMSDB, summary.peakRMSDB)
        XCTAssertFalse(summary.levelEnvelope.isEmpty, "음량 엔벨로프가 생성되지 않음")
        XCTAssertGreaterThan(Double(summary.levelEnvelope.count) * summary.envelopeBucketSeconds, 10.0)
    }

    func testRecordRoundTripPreservesAnalysisMetadata() throws {
        let event = AgitationEvent(
            startedAtOffset: 5.0,
            endedAtOffset: 8.2,
            peakScore: 0.88,
            peakRMSDB: -12.4,
            peakPitchHz: 288.0,
            frameCount: 64
        )
        let record = RecordingSessionRecord(
            fileName: "vg_test.m4a",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_020),
            durationSeconds: 20,
            peakAgitationScore: 0.88,
            triggerReason: "성량 +18dB · 고음 피치(288Hz) 급등",
            note: "메모",
            isStarred: true,
            peakRMSDB: -12.4,
            averageRMSDB: -38.1,
            maxPitchHz: 288.0,
            agitatedSeconds: 3.2,
            agitationEvents: [event],
            levelEnvelope: [-52, -48, -20, -14],
            envelopeBucketSeconds: 0.5
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(RecordingSessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.agitationEvents.first?.durationSeconds ?? 0, 3.2, accuracy: 0.0001)
        XCTAssertTrue(decoded.hasAnalysisMetadata)
        XCTAssertEqual(decoded.analysisSummary.events.count, 1)
    }

    func testLegacyRecordWithoutAnalysisFieldsDecodes() throws {
        // v1.0에서 저장된 index.json 형식(신규 필드 없음)
        let legacyJSON = """
        [{"id":"0B1F3E1A-1111-2222-3333-444455556666","fileName":"vg_legacy.m4a","startedAt":790000000,
          "endedAt":790000018,"durationSeconds":18,"peakAgitationScore":0.81,
          "triggerReason":"성량 +18dB 급등","note":"","isStarred":false}]
        """
        let records = try JSONDecoder().decode([RecordingSessionRecord].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.fileName, "vg_legacy.m4a")
        XCTAssertEqual(record.peakRMSDB, -90.0)
        XCTAssertEqual(record.maxPitchHz, 0.0)
        XCTAssertTrue(record.agitationEvents.isEmpty)
        XCTAssertFalse(record.hasAnalysisMetadata)

        // 다시 저장했을 때도 읽을 수 있어야 한다(마이그레이션 경로)
        let reencoded = try JSONEncoder().encode(record)
        let reloaded = try JSONDecoder().decode(RecordingSessionRecord.self, from: reencoded)
        XCTAssertEqual(reloaded, record)
    }

    func testReportFormatterProducesReadableSummary() {
        let record = RecordingSessionRecord(
            fileName: "vg.m4a",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_020),
            durationSeconds: 20,
            peakAgitationScore: 0.91,
            triggerReason: "성량 +22dB 급등",
            peakRMSDB: -11.2,
            averageRMSDB: -36.5,
            maxPitchHz: 312.0,
            agitatedSeconds: 4.0,
            agitationEvents: [
                AgitationEvent(startedAtOffset: 5.0, endedAtOffset: 9.0, peakScore: 0.91, peakRMSDB: -11.2, peakPitchHz: 312.0)
            ]
        )

        let text = SessionReportFormatter.reportText(record: record)
        XCTAssertTrue(text.contains("[VoiceGuard 분석 리포트]"))
        XCTAssertTrue(text.contains("피크 음량: -11dB"))
        XCTAssertTrue(text.contains("격양 구간 합계: 4.0초 (1회)"))
        XCTAssertTrue(text.contains("00:05.0 ~ 00:09.0"))

        XCTAssertEqual(SessionReportFormatter.timestampText(0), "00:00.0")
        XCTAssertEqual(SessionReportFormatter.timestampText(65.42), "01:05.4")
    }
}
