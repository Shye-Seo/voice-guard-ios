import XCTest
import VoiceGuardCore

final class VoiceGuardAppTests: XCTestCase {
    func testRecordingSessionRecordCodableRoundTrip() throws {
        let now = Date()
        let record = RecordingSessionRecord(
            fileName: "vg_test.m4a",
            startedAt: now,
            endedAt: now.addingTimeInterval(18),
            durationSeconds: 18,
            peakAgitationScore: 0.87,
            triggerReason: "성량 +18dB · 고음 피치(285Hz) 급등",
            note: "테스트 메모",
            isStarred: true
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(RecordingSessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func testRecordWithAnalysisMetadataBuildsShareableReport() {
        let record = RecordingSessionRecord(
            fileName: "vg_report.m4a",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_030),
            durationSeconds: 30,
            peakAgitationScore: 0.93,
            triggerReason: "성량 +21dB · 고음 피치(301Hz) 급등",
            note: "저녁 식사 중 언쟁",
            peakRMSDB: -10.8,
            averageRMSDB: -35.2,
            maxPitchHz: 301.0,
            agitatedSeconds: 6.4,
            agitationEvents: [
                AgitationEvent(startedAtOffset: 5.0, endedAtOffset: 8.1, peakScore: 0.93, peakRMSDB: -10.8, peakPitchHz: 301.0),
                AgitationEvent(startedAtOffset: 22.5, endedAtOffset: 25.8, peakScore: 0.88, peakRMSDB: -13.2, peakPitchHz: 288.0)
            ],
            levelEnvelope: [-52, -49, -21, -11, -30, -48, -50, -22, -14],
            envelopeBucketSeconds: 0.5
        )

        XCTAssertTrue(record.hasAnalysisMetadata)
        XCTAssertEqual(record.analysisSummary.events.count, 2)

        let report = SessionReportFormatter.reportText(record: record)
        XCTAssertTrue(report.contains("피크 음량: -11dB"))
        XCTAssertTrue(report.contains("격양 구간 합계: 6.4초 (2회)"))
        XCTAssertTrue(report.contains("[격양 구간 타임라인]"))
        XCTAssertTrue(report.contains("저녁 식사 중 언쟁"))
    }

    func testLegacyIndexJSONStillLoads() throws {
        let legacyData = Data("""
        [{"id":"11111111-2222-3333-4444-555555555555","fileName":"vg_old.m4a","startedAt":790000000,
          "endedAt":790000012,"durationSeconds":12,"peakAgitationScore":0.77,
          "triggerReason":"성량 +15dB 급등"}]
        """.utf8)

        let records = try JSONDecoder().decode([RecordingSessionRecord].self, from: legacyData)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].note, "")
        XCTAssertFalse(records[0].hasAnalysisMetadata)
        XCTAssertTrue(records[0].agitationEvents.isEmpty)
    }
}
