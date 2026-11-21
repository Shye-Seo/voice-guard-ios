import XCTest
@testable import VoiceGuardCore

final class SpeechTranscribingTests: XCTestCase {
    private let sampleSegments = [
        SpeechTranscriptSegment(text: "두 번째 발화", startedAtOffset: 6.0, endedAtOffset: 8.0, confidence: 0.8),
        SpeechTranscriptSegment(text: "첫 번째 발화", startedAtOffset: 1.0, endedAtOffset: 3.0, confidence: 0.9),
        SpeechTranscriptSegment(text: "  ", startedAtOffset: 4.0, endedAtOffset: 5.0)
    ]

    func testScriptedTranscriberReturnsFileSpecificScriptSorted() async throws {
        let transcriber = ScriptedSpeechTranscriber(
            scripts: [
                "vg_episode.m4a": sampleSegments
            ],
            fallbackScript: [SpeechTranscriptSegment(text: "기본 발화", startedAtOffset: 0, endedAtOffset: 1)]
        )
        let url = URL(fileURLWithPath: "/tmp/Recordings/vg_episode.m4a")
        let result = try await transcriber.transcribe(audioFileURL: url)

        XCTAssertEqual(result.map(\.text), ["첫 번째 발화", "두 번째 발화"])
        XCTAssertTrue(transcriber.isOnDevice)
        XCTAssertEqual(result.map(\.startedAtOffset), [1.0, 6.0])
    }

    func testScriptedTranscriberUsesFallbackForUnknownFile() async throws {
        let transcriber = ScriptedSpeechTranscriber(
            fallbackScript: [SpeechTranscriptSegment(text: "기본 발화", startedAtOffset: 0, endedAtOffset: 1)]
        )
        let result = try await transcriber.transcribe(audioFileURL: URL(fileURLWithPath: "/tmp/other.m4a"))
        XCTAssertEqual(result.map(\.text), ["기본 발화"])
    }

    func testScriptedTranscriberIsDeterministic() async throws {
        let transcriber = ScriptedSpeechTranscriber(scripts: ["vg.m4a": sampleSegments])
        let url = URL(fileURLWithPath: "/tmp/vg.m4a")
        let first = try await transcriber.transcribe(audioFileURL: url)
        let second = try await transcriber.transcribe(audioFileURL: url)
        XCTAssertEqual(first, second)
    }

    func testUnavailableTranscriberThrowsUnavailable() async {
        let transcriber = UnavailableSpeechTranscriber(reason: "시뮬레이터 테스트")
        do {
            _ = try await transcriber.transcribe(audioFileURL: URL(fileURLWithPath: "/tmp/vg.m4a"))
            XCTFail("예외가 발생해야 한다")
        } catch let error as SpeechTranscriptionError {
            XCTAssertEqual(error, .unavailable(reason: "시뮬레이터 테스트"))
            XCTAssertTrue(error.errorDescription?.contains("온디바이스") ?? false)
        } catch {
            XCTFail("예상과 다른 오류: \(error)")
        }
    }

    func testSegmentClampsNegativeRangesAndConfidence() {
        let segment = SpeechTranscriptSegment(
            text: "음수 구간",
            startedAtOffset: -3,
            endedAtOffset: -1,
            confidence: 3.4
        )
        XCTAssertEqual(segment.startedAtOffset, 0)
        XCTAssertEqual(segment.endedAtOffset, 0)
        XCTAssertEqual(segment.durationSeconds, 0)
        XCTAssertEqual(segment.confidence, 1.0)
    }

    func testOverlapSecondsWithAgitationEvent() {
        let segment = SpeechTranscriptSegment(text: "겹침", startedAtOffset: 4.0, endedAtOffset: 9.0)
        let event = AgitationEvent(startedAtOffset: 7.0, endedAtOffset: 12.0, peakScore: 0.9, peakRMSDB: -10, peakPitchHz: 300)
        XCTAssertEqual(segment.overlapSeconds(with: event), 2.0, accuracy: 0.001)

        let distant = AgitationEvent(startedAtOffset: 20.0, endedAtOffset: 22.0, peakScore: 0.5, peakRMSDB: -20, peakPitchHz: 200)
        XCTAssertEqual(segment.overlapSeconds(with: distant), 0, accuracy: 0.001)
    }

    func testNormalizerClampsToDurationAndCollapsesWhitespace() {
        let segments = [
            SpeechTranscriptSegment(text: "  여러   줄\n발화  ", startedAtOffset: 1.0, endedAtOffset: 4.0),
            SpeechTranscriptSegment(text: "끝을 넘는 발화", startedAtOffset: 58.0, endedAtOffset: 63.0)
        ]
        let normalized = SpeechTranscriptNormalizer.normalize(segments, duration: 60)
        XCTAssertEqual(normalized[0].text, "여러 줄 발화")
        XCTAssertEqual(normalized[1].endedAtOffset, 60)
    }
}
