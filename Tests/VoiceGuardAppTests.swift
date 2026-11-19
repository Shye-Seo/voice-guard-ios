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
}
